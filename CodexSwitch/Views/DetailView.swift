import SwiftUI

enum DetailTab: String, CaseIterable {
    case status = "Status"
    case providers = "Providers"
    case settings = "Settings"
    case logs = "Logs"
}

struct DetailView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: DetailTab = .status

    var body: some View {
        VStack(spacing: 0) {
            // Top segmented tab bar (à la CD-Switch)
            Picker("", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Full-width tab content
            Group {
                switch selectedTab {
                case .status:
                    ConnectionStatusView()
                        .environmentObject(appState)
                case .providers:
                    ProviderListView()
                        .environmentObject(appState)
                case .settings:
                    SettingsView()
                        .environmentObject(appState)
                case .logs:
                    LogsView()
                        .environmentObject(appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Logs View (standalone tab)

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
                .buttonStyle(.borderless)
                .help("Clear request log")
                .disabled(appState.requestLogs.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if appState.requestLogs.isEmpty {
                VStack {
                    Spacer()
                    Text("No requests yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.requestLogs) { log in
                            LogRow(log: log)
                            Divider()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct LogRow: View {
    let log: ProxyRequestLog

    var body: some View {
        HStack(spacing: 10) {
            Text(log.timestamp, style: .time)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)

            Text(log.method)
                .font(.system(.caption, design: .monospaced).bold())
                .frame(width: 48, alignment: .leading)

            Text("\(log.status)")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(statusColor(log.status))
                .frame(width: 40, alignment: .leading)

            Text(log.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let provider = log.providerName {
                Text(provider)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .trailing)
            }

            Text(String(format: "%.1fs", log.duration))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .help(log.error ?? "\(log.method) \(log.path)")
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
