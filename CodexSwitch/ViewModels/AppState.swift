import Foundation
import Combine
import AppKit
import os.log

private let logger = Logger(subsystem: "com.codex.switch", category: "app")

final class AppState: ObservableObject {
    static let shared = AppState()

    var quitRequested = false

    @Published var providers: [CodexProvider] {
        didSet { saveProviders() }
    }
    @Published var activeProviderId: UUID? {
        didSet { saveActiveProviderId() }
    }
    @Published var proxyPort: Int {
        didSet {
            AppEnvironment.shared.set(proxyPort, forKey: "proxyPort")
            restartProxyAfterPortChange(from: oldValue)
        }
    }
    @Published var gatewayToken: String {
        didSet {
            AppEnvironment.shared.set(gatewayToken, forKey: "gatewayToken")
            proxyServer.updateToken(gatewayToken)
        }
    }
    @Published var autoStartProxy: Bool {
        didSet { AppEnvironment.shared.set(autoStartProxy, forKey: "autoStartProxy") }
    }
    @Published var outboundProxyURL: String {
        didSet {
            let trimmed = outboundProxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if outboundProxyURL != trimmed {
                outboundProxyURL = trimmed
                return
            }
            AppEnvironment.shared.set(trimmed, forKey: "outboundProxyURL")
            if NetworkSessionManager.validationError(for: trimmed) == nil {
                NetworkSessionManager.shared.updateProxyURL(trimmed)
            }
        }
    }
    @Published var codexConfigPath: String {
        didSet { AppEnvironment.shared.set(codexConfigPath, forKey: "codexConfigPath") }
    }
    /// When on, switching to a third-party provider authenticates via the
    /// provider-scoped `experimental_bearer_token` in config.toml and leaves
    /// `auth.json` untouched, so a cached ChatGPT login survives switches.
    @Published var preserveOfficialAuth: Bool {
        didSet { AppEnvironment.shared.set(preserveOfficialAuth, forKey: "preserveOfficialAuth") }
    }
    @Published private(set) var proxyRunning = false
    @Published private(set) var requestLogs: [ProxyRequestLog] = []

    let proxyServer = ProxyServer()
    private var cancellables = Set<AnyCancellable>()

    var activeProvider: CodexProvider? {
        providers.first { $0.id == activeProviderId }
    }

    var outboundProxyValidationMessage: String? {
        NetworkSessionManager.validationError(for: outboundProxyURL)
    }

    var isApplied: Bool {
        guard let provider = activeProvider, !provider.isOfficial else { return false }
        let configPath = AppEnvironment.configTOMLPath
        guard FileManager.default.fileExists(atPath: configPath) else { return false }
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
        return content.contains(provider.name)
    }

    var isDirectMode: Bool {
        guard let provider = activeProvider else { return false }
        return !provider.isOfficial && provider.apiFormat == .responses
    }

    private init() {
        let defaults = AppEnvironment.shared

        self.proxyPort = defaults.object(forKey: "proxyPort") as? Int ?? AppEnvironment.defaultPort
        self.autoStartProxy = defaults.bool(forKey: "autoStartProxy")
        self.outboundProxyURL = defaults.string(forKey: "outboundProxyURL") ?? ""
        self.codexConfigPath = defaults.string(forKey: "codexConfigPath") ?? AppEnvironment.defaultCodexConfigPath
        self.preserveOfficialAuth = defaults.bool(forKey: "preserveOfficialAuth")

        // Load or generate gateway token
        if let stored = defaults.string(forKey: "gatewayToken"), !stored.isEmpty {
            self.gatewayToken = stored
        } else {
            let newToken = "cs-\(UUID().uuidString.lowercased())"
            self.gatewayToken = newToken
            defaults.set(newToken, forKey: "gatewayToken")
        }

        // Load providers
        if let data = defaults.data(forKey: "providers"),
           let decoded = try? JSONDecoder().decode([CodexProvider].self, from: data) {
            self.providers = decoded
        } else {
            self.providers = PresetProviders.builtInProviders()
        }
        self.providers = Self.providersWithOfficialPreset(self.providers)

        self.activeProviderId = {
            if let str = defaults.string(forKey: "activeProviderId") {
                return UUID(uuidString: str)
            }
            return nil
        }()

        NetworkSessionManager.shared.updateProxyURL(outboundProxyURL)

        // Bind proxy state
        proxyServer.$running
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.proxyRunning = running
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        proxyServer.$requestLogs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] logs in
                self?.requestLogs = logs
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Provider Management

    func addProvider(_ provider: CodexProvider) {
        providers.append(provider)
    }

    func removeProvider(_ provider: CodexProvider) {
        guard !provider.isOfficial else { return }
        providers.removeAll { $0.id == provider.id }
        if activeProviderId == provider.id {
            activeProviderId = nil
        }
    }

    func updateProvider(_ provider: CodexProvider) {
        guard !provider.isOfficial else { return }
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            let isActiveProvider = provider.id == activeProviderId
            providers[idx] = provider
            objectWillChange.send()
            if isActiveProvider {
                if proxyServer.running {
                    syncRunningProxy(provider: provider, showRestartNotice: true)
                } else if isApplied {
                    // Re-apply config even if proxy not running
                    try? CodexConfigManager.applyProvider(provider, port: proxyPort, gatewayToken: gatewayToken, preserveOfficialAuth: preserveOfficialAuth)
                }
            }
        }
    }

    func duplicateProvider(_ provider: CodexProvider) -> CodexProvider {
        guard !provider.isOfficial else { return provider }
        var copy = provider
        copy.id = UUID()
        copy.name = "\(provider.name) Copy"
        copy.isOfficial = false
        addProvider(copy)
        return copy
    }

    func setActive(_ provider: CodexProvider) {
        if activeProviderId == provider.id {
            if provider.isOfficial {
                restoreOfficialCodexConfig()
            }
            return
        }
        activeProviderId = provider.id
        if provider.isOfficial {
            restoreOfficialCodexConfig()
            return
        }
        if proxyServer.running, let activeProvider {
            syncRunningProxy(provider: activeProvider, showRestartNotice: true)
        }
    }

    // MARK: - Proxy

    func startProxy() {
        guard let provider = activeProvider else {
            proxyServer.lastError = "Select a provider before starting"
            logger.warning("No active provider selected")
            return
        }

        if provider.isOfficial {
            restoreOfficialCodexConfig()
            return
        }

        let preflightErrors = preflightErrors(provider: provider)
        guard preflightErrors.isEmpty else {
            proxyServer.lastError = preflightErrors.joined(separator: "\n")
            logger.error("Preflight failed: \(preflightErrors.joined(separator: "; "))")
            return
        }

        // Apply config
        do {
            try CodexConfigManager.applyProvider(provider, port: proxyPort, gatewayToken: gatewayToken, preserveOfficialAuth: preserveOfficialAuth)
        } catch {
            proxyServer.lastError = "Failed to apply Codex config: \(error.localizedDescription)"
            logger.error("Failed to apply config: \(error.localizedDescription)")
            return
        }

        // Only start proxy if provider uses Chat Completions API
        if provider.apiFormat == .chatCompletions {
            do {
                try proxyServer.start(port: proxyPort, provider: provider, gatewayToken: gatewayToken)
                logger.info("Started proxy on port \(self.proxyPort)")
            } catch {
                proxyServer.lastError = "Failed to start proxy: \(error.localizedDescription)"
                logger.error("Failed to start proxy: \(error.localizedDescription)")
            }
        } else {
            // Direct mode — config written, no proxy needed
            logger.info("Direct mode — config applied, no proxy needed")
        }
    }

    func stopProxy() {
        proxyServer.stop()
        logger.info("Stopped proxy")
    }

    func requestQuit() {
        quitRequested = true
        NSApp.terminate(nil)
    }

    // MARK: - Persistence

    private func saveProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            AppEnvironment.shared.set(data, forKey: "providers")
        }
    }

    private static func providersWithOfficialPreset(_ providers: [CodexProvider]) -> [CodexProvider] {
        var normalized = providers
        if let idx = normalized.firstIndex(where: { $0.id == CodexProvider.officialProviderId || $0.isOfficial }) {
            normalized[idx] = PresetProviders.officialProvider
        } else {
            normalized.insert(PresetProviders.officialProvider, at: 0)
        }
        return normalized
    }

    private func saveActiveProviderId() {
        AppEnvironment.shared.set(activeProviderId?.uuidString, forKey: "activeProviderId")
    }

    private func restartProxyAfterPortChange(from oldPort: Int) {
        guard oldPort != proxyPort else { return }
        guard (1...65535).contains(proxyPort) else {
            proxyServer.lastError = "Port must be between 1 and 65535"
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.startProxy()
        }
    }

    private func syncRunningProxy(provider: CodexProvider, showRestartNotice: Bool) {
        guard !provider.isOfficial else {
            restoreOfficialCodexConfig()
            return
        }

        let preflightErrors = preflightErrors(provider: provider)
        guard preflightErrors.isEmpty else {
            proxyServer.lastError = preflightErrors.joined(separator: "\n")
            logger.error("Preflight failed while updating: \(preflightErrors.joined(separator: "; "))")
            return
        }

        do {
            try CodexConfigManager.applyProvider(provider, port: proxyPort, gatewayToken: gatewayToken, preserveOfficialAuth: preserveOfficialAuth)

            if provider.apiFormat == .chatCompletions {
                if proxyServer.running {
                    proxyServer.updateProvider(provider)
                } else {
                    try proxyServer.start(port: proxyPort, provider: provider, gatewayToken: gatewayToken)
                }
            } else {
                // Direct mode — stop proxy if running
                proxyServer.stop()
            }

            logger.info("Updated provider and Codex config")
            if showRestartNotice {
                showCodexRestartNotice()
            }
        } catch {
            proxyServer.lastError = "Failed to apply Codex config: \(error.localizedDescription)"
            logger.error("Failed to apply config: \(error.localizedDescription)")
        }
    }

    private func showCodexRestartNotice() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Codex CLI Restart Required"
            alert.informativeText = "Restart Codex CLI for changes to take effect."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func preflightErrors(provider: CodexProvider) -> [String] {
        var errors: [String] = []
        if provider.isOfficial {
            return errors
        }

        if provider.apiFormat == .chatCompletions {
            if !(1...65535).contains(proxyPort) {
                errors.append("Port must be between 1 and 65535")
            } else if !proxyServer.running || proxyServer.port != proxyPort {
                let occupants = portOccupants(proxyPort)
                if !occupants.isEmpty {
                    errors.append("Port \(proxyPort) is already in use by \(occupants.joined(separator: ", "))")
                }
            }
        }

        let trimmedBaseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmedBaseURL),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           url.host != nil {
            // Valid
        } else {
            errors.append("Active provider has an invalid Base URL")
        }

        if provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Active provider API key is empty")
        }

        if provider.modelCatalog.isEmpty {
            errors.append("Active provider has no models in catalog")
        } else if provider.modelCatalog.contains(where: { $0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            errors.append("Every model needs an actual model ID")
        }

        let configDir = AppEnvironment.codexConfigPath
        let parentDir = (configDir as NSString).deletingLastPathComponent
        if !FileManager.default.isWritableFile(atPath: configDir) &&
           !FileManager.default.isWritableFile(atPath: parentDir) {
            errors.append("Codex config directory is not writable: \(configDir)")
        }

        return errors
    }

    private func portOccupants(_ port: Int) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { return nil }
                return "\(parts[0]) (pid \(parts[1]))"
            }
    }

    // MARK: - Test Connection

    func testConnection(provider: CodexProvider, completion: @escaping (Result<String, Error>) -> Void) {
        guard !provider.isOfficial else {
            completion(.success("OpenAI Official uses ChatGPT login authentication"))
            return
        }

        let endpoint: String
        if provider.apiFormat == .chatCompletions {
            endpoint = "/v1/chat/completions"
        } else {
            endpoint = "/v1/responses"
        }

        guard let url = URL(string: provider.baseURL + endpoint) else {
            completion(.failure(NSError(domain: "test", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let testBody: [String: Any]
        if provider.apiFormat == .chatCompletions {
            testBody = [
                "model": provider.modelCatalog.first?.model ?? "gpt-4",
                "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]]
            ]
        } else {
            testBody = [
                "model": provider.modelCatalog.first?.model ?? "gpt-4",
                "input": "hi"
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: testBody)

        NetworkSessionManager.shared.session.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 || status == 400 || status == 401 || status == 403 {
                let msg: String
                if status == 200 {
                    msg = "Connection successful (HTTP 200)"
                } else if status == 401 || status == 403 {
                    msg = "API key rejected (HTTP \(status))"
                } else {
                    msg = "Server reachable (HTTP \(status))"
                }
                DispatchQueue.main.async { completion(.success(msg)) }
            } else {
                let msg = "Unexpected response (HTTP \(status))"
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "test", code: status,
                        userInfo: [NSLocalizedDescriptionKey: msg])))
                }
            }
        }.resume()
    }

    private func restoreOfficialCodexConfig() {
        do {
            proxyServer.stop()
            try CodexConfigManager.restoreOfficial()
            showCodexRestartNotice()
            logger.info("Restored Codex CLI to official mode")
        } catch {
            proxyServer.lastError = "Failed to restore Codex official config: \(error.localizedDescription)"
            logger.error("Failed to restore official config: \(error.localizedDescription)")
        }
    }
}
