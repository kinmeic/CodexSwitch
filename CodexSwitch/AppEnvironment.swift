import Foundation

enum AppEnvironment {
    static let suiteName = "com.codex.switch"
    static let shared: UserDefaults = {
        UserDefaults(suiteName: suiteName) ?? .standard
    }()

    static let defaultPort = 16827

    static var defaultCodexConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex").path
    }

    static var codexConfigPath: String {
        AppEnvironment.shared.string(forKey: "codexConfigPath") ?? defaultCodexConfigPath
    }

    static var authJSONPath: String {
        "\(codexConfigPath)/auth.json"
    }

    static var configTOMLPath: String {
        "\(codexConfigPath)/config.toml"
    }

    static var modelCatalogPath: String {
        "\(codexConfigPath)/cc-switch-model-catalog.json"
    }

    static var modelsCachePath: String {
        "\(codexConfigPath)/models_cache.json"
    }

    /// A stable per-install id (8 hex chars) used to build a
    /// `prompt_cache_key` for upstream Responses-API requests, so OpenAI
    /// affinity-routes this proxy's traffic to a consistent backend and prefix
    /// caching can hit across turns. Generated once and persisted.
    static var hostKey: String {
        if let stored = shared.string(forKey: "hostKey"), !stored.isEmpty {
            return stored
        }
        let generated = Self.generateHostKey()
        shared.set(generated, forKey: "hostKey")
        return generated
    }

    private static func generateHostKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return String(UUID().uuidString.prefix(8)).lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

final class NetworkSessionManager {
    static let shared = NetworkSessionManager()

    private var currentProxyURL: String = ""
    private var currentSession: URLSession
    private let lock = NSLock()

    private init() {
        self.currentSession = NetworkSessionManager.makeSession(proxyURL: "")
    }

    var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        return currentSession
    }

    @discardableResult
    func updateProxyURL(_ proxyURL: String) -> Bool {
        let normalized = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NetworkSessionManager.validationError(for: normalized) == nil else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        guard normalized != currentProxyURL else { return true }
        currentProxyURL = normalized
        currentSession.invalidateAndCancel()
        currentSession = NetworkSessionManager.makeSession(proxyURL: normalized)
        return true
    }

    static func validationError(for proxyURL: String) -> String? {
        let normalized = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty else {
            return "Invalid proxy address. Include a scheme, such as http:// or socks5://."
        }

        guard ["http", "https", "socks", "socks5", "socks5h"].contains(scheme) else {
            return "Unsupported proxy scheme. Use http, https, socks, socks5, or socks5h."
        }

        guard let host = components.host, !host.isEmpty else {
            return "Invalid proxy address. Include a host, such as 127.0.0.1."
        }

        if let port = components.port, !(1...65535).contains(port) {
            return "Invalid proxy port. Use a value between 1 and 65535."
        }

        guard URL(string: normalized) != nil else {
            return "Invalid proxy address format."
        }

        return nil
    }

    private static func makeSession(proxyURL: String) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true

        if let proxyDictionary = proxyDictionary(for: proxyURL) {
            configuration.connectionProxyDictionary = proxyDictionary
        }

        return URLSession(configuration: configuration)
    }

    private static func proxyDictionary(for proxyURL: String) -> [AnyHashable: Any]? {
        guard !proxyURL.isEmpty, let url = URL(string: proxyURL), let scheme = url.scheme?.lowercased(), let host = url.host else {
            return nil
        }

        let port = url.port ?? defaultProxyPort(for: scheme)
        guard port > 0 else { return nil }

        switch scheme {
        case "http", "https":
            var proxy: [AnyHashable: Any] = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
            addCredentials(from: url, to: &proxy)
            return proxy
        case "socks", "socks5", "socks5h":
            var proxy: [AnyHashable: Any] = [
                kCFNetworkProxiesSOCKSEnable as String: true,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: port,
            ]
            addCredentials(from: url, to: &proxy)
            return proxy
        default:
            return nil
        }
    }

    private static func defaultProxyPort(for scheme: String) -> Int {
        switch scheme {
        case "http": return 80
        case "https": return 443
        case "socks", "socks5", "socks5h": return 1080
        default: return 0
        }
    }

    private static func addCredentials(from url: URL, to proxy: inout [AnyHashable: Any]) {
        if let user = url.user, !user.isEmpty {
            proxy[kCFProxyUsernameKey as String] = user
        }
        if let password = url.password, !password.isEmpty {
            proxy[kCFProxyPasswordKey as String] = password
        }
    }
}
