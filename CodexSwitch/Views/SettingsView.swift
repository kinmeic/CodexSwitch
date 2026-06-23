import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var l10n = Localization.shared

    var body: some View {
        Form {
            // Language switcher — header of Settings
            Section(l10n.tr("Language")) {
                Picker(selection: $l10n.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                } label: {
                    Text(l10n.tr("Language"))
                }
                .pickerStyle(.menu)
            }

            // Proxy
            Section(l10n.tr("Proxy")) {
                HStack {
                    Text(l10n.tr("Port:"))
                    Spacer()
                    TextField("", value: $appState.proxyPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                }

                Toggle(l10n.tr("Auto-start on launch"), isOn: $appState.autoStartProxy)
            }

            // Gateway Token
            Section(l10n.tr("Gateway Token")) {
                HStack {
                    Text(appState.gatewayToken)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(l10n.tr("Regenerate")) {
                        appState.gatewayToken = "cs-\(UUID().uuidString.lowercased())"
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Codex Config
            Section(l10n.tr("Codex CLI")) {
                HStack {
                    Text(l10n.tr("Config Directory:"))
                    Spacer()
                    TextField("~/.codex", text: $appState.codexConfigPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .multilineTextAlignment(.trailing)
                }

                Toggle(l10n.tr("Preserve ChatGPT login"), isOn: $appState.preserveOfficialAuth)
                    .help(l10n.tr("When on, switching to a third-party provider authenticates via experimental_bearer_token in config.toml and leaves auth.json untouched, so your cached ChatGPT login survives switches."))

                Toggle(l10n.tr("Inject prompt cache key"), isOn: $appState.injectPromptCacheKey)
                    .help(l10n.tr("When on, injects a stable prompt_cache_key into upstream Responses-API requests that omit one, so OpenAI affinity-routes to a consistent backend and prefix caching hits across turns. Responses-only; Chat Completions upstreams are unaffected."))
            }

            // Outbound Proxy
            Section(l10n.tr("Outbound Proxy")) {
                HStack {
                    Text(l10n.tr("Address:"))
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
                    Text(l10n.tr("Used by CodexSwitch outbound requests. Leave empty for direct connection."))
                    Text(verbatim: "Examples: http://127.0.0.1:7890, socks5://127.0.0.1:1080")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
