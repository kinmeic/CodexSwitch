import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            // Proxy
            Section("Proxy") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: $appState.proxyPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                Toggle("Auto-start on launch", isOn: $appState.autoStartProxy)
            }

            // Gateway Token
            Section("Gateway Token") {
                HStack {
                    Text(appState.gatewayToken)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Spacer()
                    Button("Regenerate") {
                        appState.gatewayToken = "cs-\(UUID().uuidString.lowercased())"
                    }
                }
            }

            // Codex Config
            Section("Codex CLI") {
                HStack {
                    Text("Config Directory")
                    Spacer()
                    TextField("~/.codex", text: $appState.codexConfigPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                }

                Toggle("Preserve ChatGPT login", isOn: $appState.preserveOfficialAuth)
                    .help("When on, switching to a third-party provider authenticates via experimental_bearer_token in config.toml and leaves auth.json untouched, so your cached ChatGPT login survives switches.")

                Toggle("Inject prompt cache key", isOn: $appState.injectPromptCacheKey)
                    .help("When on, injects a stable prompt_cache_key into upstream Responses-API requests that omit one, so OpenAI affinity-routes to a consistent backend and prefix caching hits across turns. Responses-only; Chat Completions upstreams are unaffected.")
            }

            // Outbound Proxy
            Section("Outbound Proxy") {
                HStack {
                    Text("URL")
                    Spacer()
                    TextField("http://proxy:8080", text: $appState.outboundProxyURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                }

                if let msg = appState.outboundProxyValidationMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}
