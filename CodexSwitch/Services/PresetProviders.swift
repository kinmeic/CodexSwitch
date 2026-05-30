import Foundation

enum PresetProviders {
    static let officialProvider = CodexProvider(
        id: CodexProvider.officialProviderId,
        name: "OpenAI Official",
        baseURL: "https://api.openai.com",
        apiKey: "",
        apiFormat: .responses,
        modelCatalog: [],
        chatReasoning: nil,
        isOfficial: true
    )

    static func builtInProviders() -> [CodexProvider] {
        [officialProvider]
    }
}
