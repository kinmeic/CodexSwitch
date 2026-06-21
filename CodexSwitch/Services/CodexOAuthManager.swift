import Foundation
import Security
import os.log

private let logger = Logger(subsystem: "com.codex.switch", category: "oauth")

/// ChatGPT Plus/Pro OAuth login for Codex CLI, via the device-code flow.
///
/// On success the access/refresh tokens are written to `~/.codex/auth.json`
/// in the Codex CLI's native ChatGPT-login schema so the CLI picks them up
/// directly — no proxy required for the official backend. Modeled on the
/// proven flow in cc-switch's `codex_oauth_auth.rs`, using the same client_id
/// the official Codex CLI ships with.
final class CodexOAuthManager: ObservableObject {

    static let shared = CodexOAuthManager()

    // MARK: - Endpoints & constants (match the official Codex CLI / cc-switch)

    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let userCodeURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    private static let pollURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let redirectURI = "https://auth.openai.com/deviceauth/callback"
    static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    private static let userAgent = "codexswitch-codex-oauth"
    private static let refreshBuffer: TimeInterval = 60   // refresh ≤60s before expiry

    // MARK: - State

    enum Phase: Equatable {
        case idle
        case awaitingUser(code: String, verificationURL: URL, expiresAt: Date)
        case exchanging
        case authenticated(account: CodexOAuthAccount)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var pollTask: Task<Void, Never>?
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Stored account

    struct CodexOAuthAccount: Codable, Equatable {
        var accountId: String
        var email: String?
        var accessToken: String
        var refreshToken: String
        var idToken: String?
        var expiresAt: Date
    }

    /// Persisted account, loaded from Keychain.
    @Published private(set) var account: CodexOAuthAccount?

    private static let keychainService = "com.codex.switch.codex-oauth"
    private static let keychainAccount = "default"

    func loadStoredAccount() {
        account = readFromKeychain()
    }

    /// Surface a previously-stored account as the authenticated phase so the
    /// UI shows the signed-in state without re-running the device flow.
    func surfaceStoredAccount(_ account: CodexOAuthAccount) {
        guard phase == .idle else { return }
        phase = .authenticated(account: account)
    }

    // MARK: - Start device flow

    func startDeviceFlow() {
        pollTask?.cancel()
        phase = .idle

        var request = URLRequest(url: Self.userCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["client_id": Self.clientID])

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    self.phase = .failed(error.localizedDescription)
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] else {
                    self.phase = .failed("Invalid response from auth server")
                    return
                }
                let deviceAuthId = (json["device_auth_id"] as? String) ?? ""
                let userCode = (json["user_code"] as? String) ?? ""
                let interval = (json["interval"] as? Double) ?? 5
                let expiresIn = (json["expires_in"] as? Double) ?? 900
                guard !deviceAuthId.isEmpty, !userCode.isEmpty else {
                    self.phase = .failed("Missing device code in response")
                    return
                }
                let expiresAt = Date().addingTimeInterval(expiresIn)
                self.phase = .awaitingUser(code: userCode, verificationURL: Self.verificationURL, expiresAt: expiresAt)
                self.beginPolling(deviceAuthId: deviceAuthId, userCode: userCode, interval: interval, expiresAt: expiresAt)
            }
        }
        task.resume()
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        if case .awaitingUser = phase { phase = .idle }
    }

    // MARK: - Polling

    private func beginPolling(deviceAuthId: String, userCode: String, interval: Double, expiresAt: Date) {
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, Date() < expiresAt {
                if let outcome = await self.pollOnce(deviceAuthId: deviceAuthId, userCode: userCode) {
                    await self.handlePollOutcome(outcome)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            if !Task.isCancelled {
                await MainActor.run { self.phase = .failed("Device code expired") }
            }
        }
    }

    private enum PollOutcome {
        case pending
        case success(authorizationCode: String, codeVerifier: String)
        case expired
        case error(String)
    }

    private func pollOnce(deviceAuthId: String, userCode: String) async -> PollOutcome? {
        var request = URLRequest(url: Self.pollURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_auth_id": deviceAuthId,
            "user_code": userCode,
        ])

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let code = json["authorization_code"] as? String,
                   let verifier = json["code_verifier"] as? String {
                    return .success(authorizationCode: code, codeVerifier: verifier)
                }
                return .error("Malformed success response")
            case 403, 404:
                return .pending
            case 410:
                return .expired
            default:
                return .error("Unexpected status \(status)")
            }
        } catch {
            // Transient network error — keep polling.
            return .pending
        }
    }

    @MainActor
    private func handlePollOutcome(_ outcome: PollOutcome) async {
        switch outcome {
        case .pending:
            return
        case .expired:
            phase = .failed("Device code expired")
        case .error(let msg):
            phase = .failed(msg)
        case .success(let code, let verifier):
            phase = .exchanging
            await exchangeCode(code, codeVerifier: verifier)
        }
    }

    // MARK: - Token exchange

    private func exchangeCode(_ code: String, codeVerifier: String) async {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": codeVerifier,
        ]
        request.httpBody = body
            .map { "\($0.key)=\(Self.urlEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                await MainActor.run { self.phase = .failed("Token exchange failed (HTTP \(status))") }
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  let refreshToken = json["refresh_token"] as? String else {
                await MainActor.run { self.phase = .failed("Missing tokens in exchange response") }
                return
            }
            let idToken = json["id_token"] as? String
            let expiresIn = (json["expires_in"] as? Double) ?? 3600
            let expiresAt = Date().addingTimeInterval(expiresIn)
            let (accountId, email) = Self.extractIdentity(accessToken: accessToken, idToken: idToken)
            guard let accountId = accountId, !accountId.isEmpty else {
                await MainActor.run { self.phase = .failed("Could not extract ChatGPT account id from token") }
                return
            }
            let account = CodexOAuthAccount(
                accountId: accountId, email: email,
                accessToken: accessToken, refreshToken: refreshToken,
                idToken: idToken, expiresAt: expiresAt
            )
            self.account = account
            self.saveToKeychain(account)
            self.writeAuthJSON(account)
            await MainActor.run { self.phase = .authenticated(account: account) }
            logger.info("Codex OAuth succeeded for account \(accountId)")
        } catch {
            await MainActor.run { self.phase = .failed("Token exchange error: \(error.localizedDescription)") }
        }
    }

    // MARK: - Refresh

    /// Refresh the access token if it is within the refresh buffer of expiry.
    /// Returns a valid access token, refreshing first if needed. On failure,
    /// clears the stored account and returns nil.
    func validAccessToken() async -> String? {
        guard let account = account else { return nil }
        if account.expiresAt.timeIntervalSinceNow > Self.refreshBuffer {
            return account.accessToken
        }
        return await refresh(account: account)
    }

    func refresh(account: CodexOAuthAccount) async -> String? {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": account.refreshToken,
            "client_id": Self.clientID,
            "scope": "openid profile email",
        ]
        request.httpBody = body
            .map { "\($0.key)=\(Self.urlEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if status == 401 || status == 403 {
                    logger.warning("Refresh token invalid; clearing stored account")
                    await MainActor.run { self.signOut() }
                }
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else { return nil }
            let refreshToken = (json["refresh_token"] as? String) ?? account.refreshToken
            let expiresIn = (json["expires_in"] as? Double) ?? 3600
            let idToken = (json["id_token"] as? String) ?? account.idToken
            let updated = CodexOAuthAccount(
                accountId: account.accountId, email: account.email,
                accessToken: accessToken, refreshToken: refreshToken,
                idToken: idToken, expiresAt: Date().addingTimeInterval(expiresIn)
            )
            self.account = updated
            self.saveToKeychain(updated)
            self.writeAuthJSON(updated)
            logger.info("Refreshed Codex OAuth token for account \(updated.accountId)")
            return accessToken
        } catch {
            logger.error("Refresh error: \(error.localizedDescription)")
            return nil
        }
    }

    func signOut() {
        pollTask?.cancel()
        pollTask = nil
        account = nil
        deleteFromKeychain()
        // Remove the OAuth tokens from auth.json, preserving any OPENAI_API_KEY.
        stripOAuthFromAuthJSON()
        phase = .idle
    }

    // MARK: - auth.json (Codex CLI native ChatGPT-login schema)

    /// Write the OAuth account into `~/.codex/auth.json` in the Codex CLI's
    /// native schema: `{"auth_mode":"chatgpt","tokens":{...},"last_refresh":...}`.
    private func writeAuthJSON(_ account: CodexOAuthAccount) {
        let path = AppEnvironment.authJSONPath
        var existing = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
            ?? [:]
        // Preserve any non-OAuth fields; overwrite the OAuth-specific ones.
        existing["auth_mode"] = "chatgpt"
        existing["tokens"] = [
            "access_token": account.accessToken,
            "account_id": account.accountId,
            "refresh_token": account.refreshToken,
            "id_token": account.idToken ?? "",
        ] as [String: Any]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        existing["last_refresh"] = formatter.string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            logger.info("Wrote Codex auth.json with ChatGPT OAuth tokens")
        }
    }

    /// Remove OAuth fields from auth.json while preserving `OPENAI_API_KEY`.
    private func stripOAuthFromAuthJSON() {
        let path = AppEnvironment.authJSONPath
        guard var existing = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
            else { return }
        existing.removeValue(forKey: "auth_mode")
        existing.removeValue(forKey: "tokens")
        existing.removeValue(forKey: "last_refresh")
        if existing.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else if let data = try? JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    // MARK: - JWT identity extraction

    /// Extract `chatgpt_account_id` (and email) from the token JWTs. Tries
    /// `id_token` first, then `access_token`. Claim precedence:
    /// `chatgpt_account_id` → `https://api.openai.com/auth.chatgpt_account_id`
    /// → `organizations[0].id`.
    static func extractIdentity(accessToken: String, idToken: String?) -> (accountId: String?, email: String?) {
        if let idToken = idToken {
            let claims = Self.parseClaims(idToken)
            if claims.accountId != nil {
                return claims
            }
        }
        return Self.parseClaims(accessToken)
    }

    private static func parseClaims(_ jwt: String) -> (accountId: String?, email: String?) {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return (nil, nil) }
        var payload = String(parts[1])
        // base64url → base64, pad
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let accountId = (claims["chatgpt_account_id"] as? String)
            ?? ((claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String)
            ?? ((claims["organizations"] as? [[String: Any]])?.first?["id"] as? String)
        let email = claims["email"] as? String
        return (accountId, email)
    }

    // MARK: - Keychain persistence

    private func saveToKeychain(_ account: CodexOAuthAccount) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func readFromKeychain() -> CodexOAuthAccount? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let account = try? JSONDecoder().decode(CodexOAuthAccount.self, from: data) else {
            return nil
        }
        return account
    }

    private func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Helpers

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
