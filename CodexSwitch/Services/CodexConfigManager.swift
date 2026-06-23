import Foundation
import os.log

private let logger = Logger(subsystem: "com.codex.switch", category: "config")

enum CodexConfigManager {

    // MARK: - Apply Provider

    static func applyProvider(
        _ provider: CodexProvider,
        port: Int,
        gatewayToken: String,
        preserveOfficialAuth: Bool = false
    ) throws {
        let paths = resolvePaths()
        let snapshot = snapshotFiles([paths.configTOMLPath, paths.modelCatalogPath, paths.authJSONPath])

        do {
            try ensureDirectoryExists(paths.codexConfigPath)

            // Write config.toml
            try writeConfigTOML(provider: provider, port: port, gatewayToken: gatewayToken,
                               configPath: paths.configTOMLPath)

            // Add model catalog (only if provider has models)
            if !provider.modelCatalog.isEmpty {
                try writeModelCatalog(provider.modelCatalog, catalogPath: paths.modelCatalogPath,
                                     configPath: paths.configTOMLPath)
            }

            // Write auth.json — third-party providers may skip this to keep the
            // user's ChatGPT login cache (auth.json) intact across switches.
            // Authentication then flows through the provider-scoped
            // experimental_bearer_token written into config.toml above (direct
            // mode) or through the in-memory proxy gateway (proxy mode).
            if shouldWriteAuthJSON(for: provider, preserveOfficialAuth: preserveOfficialAuth) {
                try writeAuthJSON(apiKey: provider.apiKey, authPath: paths.authJSONPath)
            } else {
                logger.info("Skipped auth.json write to preserve ChatGPT login for '\(provider.name)'")
            }

            logger.info("Applied provider '\(provider.name)' to Codex config")
        } catch {
            restoreFiles(snapshot)
            logger.error("Rolled back Codex config after apply failure: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Restore Official

    static func restoreOfficial() throws {
        let paths = resolvePaths()

        // Remove custom config.toml
        if FileManager.default.fileExists(atPath: paths.configTOMLPath) {
            try FileManager.default.removeItem(atPath: paths.configTOMLPath)
        }

        // Remove model catalog
        if FileManager.default.fileExists(atPath: paths.modelCatalogPath) {
            try FileManager.default.removeItem(atPath: paths.modelCatalogPath)
        }

        // Preserve auth.json (contains ChatGPT login cache)
        logger.info("Restored Codex CLI to official mode")
    }

    /// Whether applying `provider` should overwrite `auth.json`.
    ///
    /// Official providers always own `auth.json` when they carry a key.
    /// Third-party providers skip the write when `preserveOfficialAuth` is on,
    /// authenticating via `experimental_bearer_token` in `config.toml` instead
    /// so the user's ChatGPT login cache survives provider switches.
    private static func shouldWriteAuthJSON(
        for provider: CodexProvider,
        preserveOfficialAuth: Bool
    ) -> Bool {
        let hasKey = !provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if provider.isOfficial {
            return hasKey
        }
        return hasKey && !preserveOfficialAuth
    }

    // MARK: - Paths

    private struct Paths {
        let codexConfigPath: String
        let authJSONPath: String
        let configTOMLPath: String
        let modelCatalogPath: String
    }

    private static func resolvePaths() -> Paths {
        let base = AppEnvironment.codexConfigPath
        return Paths(
            codexConfigPath: base,
            authJSONPath: "\(base)/auth.json",
            configTOMLPath: "\(base)/config.toml",
            modelCatalogPath: "\(base)/\(AppEnvironment.CodexCatalogFilename)"
        )
    }

    // MARK: - config.toml Writing

    private static func writeConfigTOML(
        provider: CodexProvider,
        port: Int,
        gatewayToken: String,
        configPath: String
    ) throws {
        let baseURL: String
        let authToken: String

        if provider.apiFormat == .chatCompletions {
            // Proxy mode: point to local proxy
            baseURL = "http://127.0.0.1:\(port)"
            authToken = gatewayToken
        } else {
            // Direct mode: point to actual provider URL
            baseURL = provider.baseURL
            authToken = provider.apiKey
        }

        let firstModel = provider.modelCatalog.first?.model ?? "gpt-5.5"
        let contextWindow = provider.modelCatalog.first?.contextWindow
        let escapedName = tomlEscape(provider.name)
        let escapedURL = tomlEscape(baseURL)
        let escapedToken = tomlEscape(authToken)
        let escapedModel = tomlEscape(firstModel)

        // Build top-level section
        var toml = """
        model_provider = "custom"
        model = "\(escapedModel)"

        """

        // review_model (omitted when empty)
        let reviewModel = provider.reviewModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reviewModel.isEmpty {
            toml += "review_model = \"\(tomlEscape(reviewModel))\"\n"
        }

        toml += """
        model_reasoning_effort = "high"
        disable_response_storage = true

        [model_providers.custom]
        name = "\(escapedName)"
        base_url = "\(escapedURL)"
        wire_api = "responses"
        requires_openai_auth = true
        experimental_bearer_token = "\(escapedToken)"

        """

        // model_context_window and model_auto_compact_token_limit (90% of context window)
        if let ctx = contextWindow, ctx > 0 {
            toml += "model_context_window = \(ctx)\n"
            let compactLimit = Int(Double(ctx) * 0.9)
            toml += "model_auto_compact_token_limit = \(compactLimit)\n"
        }

        // Add model catalog path if provider has models — write only the
        // filename (relative), not the absolute path. Codex CLI resolves it
        // relative to the config directory; absolute paths are not supported.
        if !provider.modelCatalog.isEmpty {
            toml += "model_catalog_json = \"\(AppEnvironment.CodexCatalogFilename)\"\n"
        }

        // [features] goals
        if provider.goalsEnabled {
            toml += """

            [features]
            goals = true

            """
        }

        try toml.write(toFile: configPath, atomically: true, encoding: .utf8)
        logger.info("Wrote config.toml with baseURL: \(baseURL)")
    }

    // MARK: - auth.json Writing

    private static func writeAuthJSON(apiKey: String, authPath: String) throws {
        let auth: [String: Any] = [
            "OPENAI_API_KEY": apiKey
        ]
        try writeJSON(authPath, auth)
        logger.info("Wrote auth.json")
    }

    // MARK: - Model Catalog Writing

    private static func writeModelCatalog(_ models: [CodexCatalogModel], catalogPath: String,
                                           configPath: String) throws {
        // Try to read models_cache.json for template
        let template = readModelTemplate()

        let catalog: [[String: Any]] = models.enumerated().map { index, model in
            var entry: [String: Any] = [
                "slug": model.model,
                "display_name": model.displayName.isEmpty ? model.model : model.displayName,
                "description": model.displayName.isEmpty ? model.model : model.displayName,
                "priority": 1000 + index,
            ]

            if let contextWindow = model.contextWindow {
                entry["context_window"] = contextWindow
                entry["max_context_window"] = contextWindow
            }

            // Merge template fields if available
            if let baseInstructions = template["base_instructions"] {
                entry["base_instructions"] = baseInstructions
            }
            if let modelMessages = template["model_messages"] {
                entry["model_messages"] = modelMessages
            }

            // Clear OpenAI-specific fields
            entry["additional_speed_tiers"] = [] as [Any]
            entry["service_tiers"] = [] as [Any]
            entry["availability_nux"] = NSNull()
            entry["upgrade"] = NSNull()

            return entry
        }

        let wrapper: [String: Any] = ["models": catalog]
        try writeJSON(catalogPath, wrapper)
        logger.info("Wrote model catalog with \(models.count) models")
    }

    private static func readModelTemplate() -> [String: Any] {
        // Try to read ~/.codex/models_cache.json and extract gpt-5.5 template
        let cachePath = AppEnvironment.modelsCachePath
        guard let data = FileManager.default.contents(atPath: cachePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return minimalTemplate()
        }

        // models_cache.json can be either { "models": [...] } or just [...]
        let models: [[String: Any]]
        if let modelsArray = json["models"] as? [[String: Any]] {
            models = modelsArray
        } else if let topArray = json as? [[String: Any]] {
            models = topArray
        } else {
            return minimalTemplate()
        }

        // Find gpt-5.5 or any gpt model as template
        if let gpt55 = models.first(where: { ($0["slug"] as? String)?.contains("gpt-5") == true }) {
            return gpt55
        }
        if let gpt = models.first(where: { ($0["slug"] as? String)?.contains("gpt") == true }) {
            return gpt
        }
        if let first = models.first {
            return first
        }

        return minimalTemplate()
    }

    private static func minimalTemplate() -> [String: Any] {
        return [
            "base_instructions": "You are a helpful coding assistant.",
            "model_messages": [
                "instructions_template": "You are a helpful coding assistant.",
                "instructions_variables": [:] as [String: Any]
            ] as [String: Any]
        ]
    }

    // MARK: - Helpers

    private static func tomlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func ensureDirectoryExists(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    private static func writeJSON(_ path: String, _ obj: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func snapshotFiles(_ paths: [String]) -> [String: Data?] {
        var snapshot: [String: Data?] = [:]
        for path in paths {
            snapshot[path] = FileManager.default.contents(atPath: path)
        }
        return snapshot
    }

    private static func restoreFiles(_ snapshot: [String: Data?]) {
        for (path, data) in snapshot {
            if let data {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } else if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
