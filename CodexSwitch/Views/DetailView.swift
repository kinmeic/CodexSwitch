import SwiftUI

struct DetailView: View {
    var body: some View {
        TabView {
            ConnectionStatusView()
                .tabItem {
                    Label("Status", systemImage: "network")
                }

            LogsView()
                .tabItem {
                    Label("Logs", systemImage: "doc.text")
                }

            ProviderListView()
                .tabItem {
                    Label("Providers", systemImage: "server.rack")
                }

            OAuthLoginView()
                .tabItem {
                    Label("ChatGPT", systemImage: "person.badge.key")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .padding()
    }
}

// MARK: - Logs View

struct LogsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Request Logs")
                    .font(.headline)
                Spacer()
                Button {
                    appState.proxyServer.clearRequestLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(appState.requestLogs.isEmpty)
            }
            .padding(.bottom, 8)

            if appState.requestLogs.isEmpty {
                Spacer()
                Text("No requests yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.requestLogs) { log in
                            LogRow(log: log)
                        }
                    }
                }
            }
        }
    }
}

struct LogRow: View {
    let log: ProxyRequestLog

    var body: some View {
        HStack(spacing: 8) {
            Text(log.timestamp, style: .time)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(log.method)
                .font(.system(.caption, design: .monospaced).bold())
                .frame(width: 40, alignment: .leading)

            Text(statusText(log.status))
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(statusColor(log.status))
                .frame(width: 30, alignment: .leading)

            Text(log.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            if let provider = log.providerName {
                Text(provider)
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            Spacer()

            Text(String(format: "%.1fs", log.duration))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            if let error = log.error {
                Text(error)
                    .font(.system(.caption2))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusText(_ status: Int) -> String {
        "\(status)"
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return .green
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .secondary
        }
    }
}
