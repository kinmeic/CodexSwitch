import Foundation

// MARK: - API Format

enum CodexApiFormat: String, Codable, CaseIterable {
    case responses          // OpenAI Responses API — direct
    case chatCompletions    // Chat Completions — needs proxy conversion

    var displayName: String {
        switch self {
        case .responses: return "Responses API (Direct)"
        case .chatCompletions: return "Chat Completions (Proxy)"
        }
    }
}

// MARK: - Chat Reasoning Configuration

struct CodexChatReasoning: Codable, Equatable {
    var supportsThinking: Bool
    var supportsEffort: Bool
    var thinkingParam: String       // "thinking" | "enable_thinking" | "reasoning_split"
    var effortParam: String         // "reasoning_effort" | "reasoning.effort" | "none"
    var effortValueMode: String?    // "deepseek" | "low_high" | "openrouter" | nil
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
        effortValueMode: "deepseek",
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

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey, apiFormat, modelCatalog, chatReasoning, isOfficial
    }

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKey: String,
        apiFormat: CodexApiFormat = .responses,
        modelCatalog: [CodexCatalogModel] = [],
        chatReasoning: CodexChatReasoning? = nil,
        isOfficial: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiFormat = apiFormat
        self.modelCatalog = modelCatalog
        self.chatReasoning = chatReasoning
        self.isOfficial = isOfficial
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
    }
}
