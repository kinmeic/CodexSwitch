import Foundation

// MARK: - API Format

enum CodexApiFormat: String, Codable, CaseIterable {
    case responses          // OpenAI Responses API — direct
    case chatCompletions    // Chat Completions — needs proxy conversion

    var displayName: String {
        switch self {
        case .responses: return L10n.tr("Responses API (Direct)")
        case .chatCompletions: return L10n.tr("Chat Completions (Proxy)")
        }
    }
}

// MARK: - Effort Value Mode

/// Platform-specific effort value mapping dialects. Each mode defines how
/// Codex's standard effort levels (low/medium/high) translate to the
/// upstream provider's reasoning effort parameter.
enum CodexEffortValueMode: String, Codable, CaseIterable {
    /// DeepSeek-style: low/medium→low, high→high, max→max (three tiers collapsed to two + max)
    case deepseek
    /// Low/High-style: minimal/low/medium→low, high/max/xhigh→high (two tiers)
    case lowHigh
    /// OpenRouter-style: passthrough with max→xhigh (OpenRouter rejects "max")
    case openrouter

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .lowHigh: return "Low/High"
        case .openrouter: return "OpenRouter"
        }
    }
}

// MARK: - Chat Reasoning Configuration

struct CodexChatReasoning: Codable, Equatable {
    var supportsThinking: Bool
    var supportsEffort: Bool
    var thinkingParam: String       // "thinking" | "enable_thinking" | "reasoning_split"
    var effortParam: String         // "reasoning_effort" | "reasoning.effort" | "none"
    var effortValueMode: CodexEffortValueMode?    // maps effort values per platform dialect
    var outputFormat: String        // "reasoning_content" | "reasoning_details" | "reasoning"

    static let `default` = CodexChatReasoning(
        supportsThinking: false,
        supportsEffort: false,
        thinkingParam: "thinking",
        effortParam: "none",
        effortValueMode: nil,
        outputFormat: "reasoning_content"
    )

    static let deepseek = CodexChatReasoning(
        supportsThinking: true,
        supportsEffort: true,
        thinkingParam: "thinking",
        effortParam: "reasoning_effort",
        effortValueMode: .deepseek,
        outputFormat: "reasoning_content"
    )

    static let kimi = CodexChatReasoning(
        supportsThinking: true,
        supportsEffort: false,
        thinkingParam: "thinking",
        effortParam: "none",
        effortValueMode: nil,
        outputFormat: "reasoning_content"
    )

    static let qwen = CodexChatReasoning(
        supportsThinking: true,
        supportsEffort: false,
        thinkingParam: "enable_thinking",
        effortParam: "none",
        effortValueMode: nil,
        outputFormat: "reasoning_content"
    )

    static let glm = CodexChatReasoning(
        supportsThinking: true,
        supportsEffort: false,
        thinkingParam: "thinking",
        effortParam: "none",
        effortValueMode: nil,
        outputFormat: "reasoning_content"
    )

    static let minimax = CodexChatReasoning(
        supportsThinking: true,
        supportsEffort: false,
        thinkingParam: "reasoning_split",
        effortParam: "none",
        effortValueMode: nil,
        outputFormat: "reasoning_details"
    )

    static let mimo = CodexChatReasoning(
        supportsThinking: true,
        supportsEffort: false,
        thinkingParam: "thinking",
        effortParam: "none",
        effortValueMode: nil,
        outputFormat: "reasoning_content"
    )

    // MARK: - Aggregator platform dialects
    // Platform rules take precedence over model rules: a DeepSeek model hosted
    // on OpenRouter uses OpenRouter's `reasoning.effort` parameter, not
    // DeepSeek's `reasoning_effort`.

    static let openrouter = CodexChatReasoning(
        supportsThinking: false,
        supportsEffort: true,
        thinkingParam: "thinking",       // unused (OpenRouter has no thinking flag)
        effortParam: "reasoning.effort",
        effortValueMode: .openrouter,   // clamps max→xhigh (OpenRouter rejects "max")
        outputFormat: "reasoning_content"
    )

    static let siliconflow = CodexChatReasoning(
        supportsThinking: true,
        supportsEffort: false,
        thinkingParam: "enable_thinking",
        effortParam: "none",
        effortValueMode: nil,
        outputFormat: "reasoning_content"
    )
}

// MARK: - Model Catalog Entry

struct CodexCatalogModel: Identifiable, Codable, Equatable {
    var id = UUID()
    var model: String           // actual model ID sent to API
    var displayName: String     // shown in Codex UI
    var contextWindow: Int?     // token limit

    enum CodingKeys: String, CodingKey {
        case id, model, displayName, contextWindow
    }
}

// MARK: - Provider

struct CodexProvider: Identifiable, Codable, Equatable {
    static let officialProviderId = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    var id: UUID
    var name: String
    var baseURL: String
    var apiKey: String
    var apiFormat: CodexApiFormat
    var modelCatalog: [CodexCatalogModel]
    var chatReasoning: CodexChatReasoning?
    var isOfficial: Bool
    /// Model used for code review tasks (e.g. `gpt-5.5`). Written to config.toml
    /// as `review_model`. Empty string means the field is omitted.
    var reviewModel: String
    /// Enable Goal Mode (`[features] goals = true` in config.toml).
    var goalsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey, apiFormat, modelCatalog, chatReasoning, isOfficial,
             reviewModel, goalsEnabled
    }

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKey: String,
        apiFormat: CodexApiFormat = .responses,
        modelCatalog: [CodexCatalogModel] = [],
        chatReasoning: CodexChatReasoning? = nil,
        isOfficial: Bool = false,
        reviewModel: String = "gpt-5.5",
        goalsEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiFormat = apiFormat
        self.modelCatalog = modelCatalog
        self.chatReasoning = chatReasoning
        self.isOfficial = isOfficial
        self.reviewModel = reviewModel
        self.goalsEnabled = goalsEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        apiFormat = try container.decodeIfPresent(CodexApiFormat.self, forKey: .apiFormat) ?? .responses
        modelCatalog = try container.decodeIfPresent([CodexCatalogModel].self, forKey: .modelCatalog) ?? []
        chatReasoning = try container.decodeIfPresent(CodexChatReasoning.self, forKey: .chatReasoning)
        isOfficial = try container.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
        reviewModel = try container.decodeIfPresent(String.self, forKey: .reviewModel) ?? "gpt-5.5"
        goalsEnabled = try container.decodeIfPresent(Bool.self, forKey: .goalsEnabled) ?? false
    }

    /// The reasoning dialect to apply for this provider. Platform rules take
    /// precedence over model rules: a model hosted on OpenRouter uses
    /// OpenRouter's `reasoning.effort` parameter even if the model's native
    /// dialect (e.g. DeepSeek's `reasoning_effort`) would say otherwise.
    var effectiveReasoning: CodexChatReasoning? {
        if let platform = CodexProvider.platformReasoning(for: baseURL) {
            return platform
        }
        return chatReasoning
    }

    /// Detect a known aggregator platform from the base URL and return its
    /// reasoning dialect. Returns nil for model-native providers.
    static func platformReasoning(for baseURL: String) -> CodexChatReasoning? {
        let host = (URL(string: baseURL)?.host ?? baseURL).lowercased()

        if host.contains("openrouter.ai") {
            return .openrouter
        }
        if host.contains("siliconflow") {
            return .siliconflow
        }
        return nil
    }
}
