import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            // Proxy
            Section("Proxy") {
                HStack {
                    Text("Port:")
                    Spacer()
                    TextField("", value: $appState.proxyPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                }

                Toggle("Auto-start on launch", isOn: $appState.autoStartProxy)
            }

            // Gateway Token
            Section("Gateway Token") {
                HStack {
                    Text(appState.gatewayToken)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Regenerate") {
                        appState.gatewayToken = "cs-\(UUID().uuidString.lowercased())"
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Codex Config
            Section("Codex CLI") {
                HStack {
                    Text("Config Directory:")
                    Spacer()
                    TextField("~/.codex", text: $appState.codexConfigPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .multilineTextAlignment(.trailing)
                }

                Toggle("Preserve ChatGPT login", isOn: $appState.preserveOfficialAuth)
                    .help("When on, switching to a third-party provider authenticates via experimental_bearer_token in config.toml and leaves auth.json untouched, so your cached ChatGPT login survives switches.")

                Toggle("Inject prompt cache key", isOn: $appState.injectPromptCacheKey)
                    .help("When on, injects a stable prompt_cache_key into upstream Responses-API requests that omit one, so OpenAI affinity-routes to a consistent backend and prefix caching hits across turns. Responses-only; Chat Completions upstreams are unaffected.")
            }

            // Outbound Proxy
            Section("Outbound Proxy") {
                HStack {
                    Text("Address:")
                    Spacer()
                    TextField("", text: $appState.outboundProxyURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }

                if let msg = appState.outboundProxyValidationMessage {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Used by CodexSwitch outbound requests. Leave empty for direct connection.")
                    Text(verbatim: "Examples: http://127.0.0.1:7890, socks5://127.0.0.1:1080")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
