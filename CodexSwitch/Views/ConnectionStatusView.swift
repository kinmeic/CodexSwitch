import SwiftUI

struct ConnectionStatusView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var l10n = Localization.shared

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // Status Icon
            Image(systemName: statusIcon)
                .font(.system(size: 48))
                .foregroundStyle(statusColor)

            Text(statusTitle)
                .font(.title2.bold())

            // Mode indicator
            if let provider = appState.activeProvider, !provider.isOfficial {
                HStack(spacing: 6) {
                    Image(systemName: provider.apiFormat == .chatCompletions ? "arrow.left.arrow.right" : "arrow.right")
                    Text(provider.apiFormat == .chatCompletions ? l10n.tr("Proxy Mode") : l10n.tr("Direct Mode"))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            // Proxy address (only for proxy mode)
            if let provider = appState.activeProvider, !provider.isOfficial, provider.apiFormat == .chatCompletions {
                VStack(spacing: 8) {
                    HStack {
                        Text(l10n.tr("Proxy Server"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    HStack {
                        Text(verbatim: "http://127.0.0.1:\(String(format: "%d", appState.proxyPort))")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            Clipboard.copy("http://127.0.0.1:\(String(format: "%d", appState.proxyPort))")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(maxWidth: 400)
            }

            // Gateway Token
            if let provider = appState.activeProvider, !provider.isOfficial, provider.apiFormat == .chatCompletions {
                VStack(spacing: 8) {
                    HStack {
                        Text(l10n.tr("Gateway Token"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    HStack {
                        Text(appState.gatewayToken)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            Clipboard.copy(appState.gatewayToken)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .frame(maxWidth: 400)
            }

            // Active Provider
            if let provider = appState.activeProvider {
                HStack {
                    Text(l10n.tr("Active Provider:"))
                        .foregroundStyle(.secondary)
                    Text(provider.name)
                        .bold()
                    if provider.isOfficial {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.blue)
                    }
                }
                .font(.subheadline)
            }

            // Start/Stop Button
            if let provider = appState.activeProvider, !provider.isOfficial {
                if appState.proxyRunning {
                    Button(l10n.tr("Stop Proxy")) {
                        appState.stopProxy()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    Button(l10n.tr("Start")) {
                        appState.startProxy()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            // Error display
            if let error = appState.proxyServer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Spacer()

            // Version
            Text("CodexSwitch v\(appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    private var statusIcon: String {
        if appState.proxyRunning {
            return "network"
        } else if appState.isDirectMode {
            return "arrow.right.circle"
        } else {
            return "network.slash"
        }
    }

    private var statusColor: Color {
        if appState.proxyRunning {
            return .green
        } else if appState.isDirectMode {
            return .blue
        } else {
            return .secondary
        }
    }

    private var statusTitle: String {
        if appState.proxyRunning {
            return l10n.tr("Proxy Running")
        } else if appState.isDirectMode {
            return l10n.tr("Direct Mode")
        } else {
            return l10n.tr("Stopped")
        }
    }
}
