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
