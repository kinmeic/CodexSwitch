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

        // Read existing config to preserve other sections (features, mcp_servers, etc.)
        var existingLines: [String] = []
        if FileManager.default.fileExists(atPath: configPath),
           let existingContent = try? String(contentsOfFile: configPath, encoding: .utf8) {
            existingLines = existingContent.components(separatedBy: "\n")
        }

        // Parse existing config into sections
        var sections: [(name: String?, lines: [String])] = []
        var currentSection: String? = nil
        var currentLines: [String] = []

        for line in existingLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // Save previous section
                if !currentLines.isEmpty || currentSection != nil {
                    sections.append((currentSection, currentLines))
                }
                currentSection = String(trimmed.dropFirst().dropLast())
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        // Save last section
        if !currentLines.isEmpty || currentSection != nil {
            sections.append((currentSection, currentLines))
        }

        // Helper to update or add a key in a section
        func updateKey(_ key: String, value: String, in section: String?, lines: inout [String]) {
            let keyPattern = "^\(key)\\s*="
            var found = false
            for i in 0..<lines.count {
                if lines[i].range(of: keyPattern, options: .regularExpression) != nil {
                    lines[i] = "\(key) = \(value)"
                    found = true
                    break
                }
            }
            if !found {
                // Add at the end of the section (before trailing empty lines)
                var insertIdx = lines.count
                while insertIdx > 0 && lines[insertIdx - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    insertIdx -= 1
                }
                lines.insert("\(key) = \(value)", at: insertIdx)
            }
        }

        // Update top-level section (section name is nil)
        if let idx = sections.firstIndex(where: { $0.name == nil }) {
            var lines = sections[idx].lines
            updateKey("model_provider", value: "\"custom\"", in: nil, lines: &lines)
            updateKey("model", value: "\"\(escapedModel)\"", in: nil, lines: &lines)

            let reviewModel = provider.reviewModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reviewModel.isEmpty {
                updateKey("review_model", value: "\"\(tomlEscape(reviewModel))\"", in: nil, lines: &lines)
            }

            updateKey("model_reasoning_effort", value: "\"high\"", in: nil, lines: &lines)
            updateKey("disable_response_storage", value: "true", in: nil, lines: &lines)

            if let ctx = contextWindow, ctx > 0 {
                updateKey("model_context_window", value: "\(ctx)", in: nil, lines: &lines)
                let compactLimit = Int(Double(ctx) * 0.9)
                updateKey("model_auto_compact_token_limit", value: "\(compactLimit)", in: nil, lines: &lines)
            }

            if !provider.modelCatalog.isEmpty {
                updateKey("model_catalog_json", value: "\"\(AppEnvironment.CodexCatalogFilename)\"", in: nil, lines: &lines)
            }

            sections[idx].lines = lines
        } else {
            // No top-level section found, create one at the beginning
            var lines: [String] = []
            lines.append("model_provider = \"custom\"")
            lines.append("model = \"\(escapedModel)\"")

            let reviewModel = provider.reviewModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reviewModel.isEmpty {
                lines.append("review_model = \"\(tomlEscape(reviewModel))\"")
            }

            lines.append("model_reasoning_effort = \"high\"")
            lines.append("disable_response_storage = true")

            if let ctx = contextWindow, ctx > 0 {
                lines.append("model_context_window = \(ctx)")
                let compactLimit = Int(Double(ctx) * 0.9)
                lines.append("model_auto_compact_token_limit = \(compactLimit)")
            }

            if !provider.modelCatalog.isEmpty {
                lines.append("model_catalog_json = \"\(AppEnvironment.CodexCatalogFilename)\"")
            }

            sections.insert((nil, lines), at: 0)
        }

        // Update or create [model_providers.custom] section
        if let idx = sections.firstIndex(where: { $0.name == "model_providers.custom" }) {
            var lines = sections[idx].lines
            updateKey("name", value: "\"\(escapedName)\"", in: "model_providers.custom", lines: &lines)
            updateKey("base_url", value: "\"\(escapedURL)\"", in: "model_providers.custom", lines: &lines)
            updateKey("wire_api", value: "\"responses\"", in: "model_providers.custom", lines: &lines)
            updateKey("requires_openai_auth", value: "true", in: "model_providers.custom", lines: &lines)
            updateKey("experimental_bearer_token", value: "\"\(escapedToken)\"", in: "model_providers.custom", lines: &lines)
            sections[idx].lines = lines
        } else {
            // Add new section at the end
            var lines: [String] = []
            lines.append("name = \"\(escapedName)\"")
            lines.append("base_url = \"\(escapedURL)\"")
            lines.append("wire_api = \"responses\"")
            lines.append("requires_openai_auth = true")
            lines.append("experimental_bearer_token = \"\(escapedToken)\"")
            sections.append(("model_providers.custom", lines))
        }

        // Update or create [features] section for goals
        if provider.goalsEnabled {
            if let idx = sections.firstIndex(where: { $0.name == "features" }) {
                var lines = sections[idx].lines
                updateKey("goals", value: "true", in: "features", lines: &lines)
                sections[idx].lines = lines
            } else {
                var lines: [String] = []
                lines.append("goals = true")
                sections.append(("features", lines))
            }
        }

        // Reconstruct the file
        var output: [String] = []
        for (sectionName, lines) in sections {
            if let name = sectionName {
                if !output.isEmpty && !output.last!.isEmpty {
                    output.append("")
                }
                output.append("[\(name)]")
            }
            output.append(contentsOf: lines)
        }

        let toml = output.joined(separator: "\n")
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
        // Load the full gpt-5.5 template from models_cache.json — Codex CLI
        // requires catalog entries to contain many fields (visibility,
        // supported_in_api, shell_type, supported_reasoning_levels, etc.).
        // We clone the entire template and override only 10 fields, matching
        // the cc-switch Rust implementation exactly.
        let template = readModelTemplate()

        let catalog: [[String: Any]] = models.enumerated().map { index, model in
            // Start with a full clone of the template, then override specific fields
            var entry = template

            let displayName = model.displayName.isEmpty ? model.model : model.displayName
            entry["slug"] = model.model
            entry["display_name"] = displayName
            entry["description"] = displayName

            if let contextWindow = model.contextWindow {
                entry["context_window"] = contextWindow
                entry["max_context_window"] = contextWindow
            }

            entry["priority"] = 1000 + index

            // Clear OpenAI-specific fields so third-party providers don't
            // inherit GPT-5.5 speed tiers, service tiers, or launch messaging
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
            "slug": "gpt-5.5",
            "display_name": "GPT-5.5",
            "description": "Codex agent model",
            "base_instructions": "You are a helpful coding assistant.",
            "model_messages": [
                "instructions_template": "You are a helpful coding assistant.",
                "instructions_variables": [:] as [String: Any]
            ] as [String: Any],
            "supported_reasoning_levels": [
                ["effort": "low", "description": "Fast responses for simple tasks"],
                ["effort": "medium", "description": "Balanced speed and quality"],
                ["effort": "high", "description": "Thorough reasoning for complex tasks"],
                ["effort": "xhigh", "description": "Maximum reasoning depth"]
            ] as [[String: Any]],
            "default_reasoning_level": "medium",
            "visibility": "list",
            "supported_in_api": true,
            "shell_type": "shell_command",
            "priority": 0,
            "additional_speed_tiers": [] as [Any],
            "service_tiers": [] as [Any],
            "availability_nux": NSNull(),
            "upgrade": NSNull(),
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
