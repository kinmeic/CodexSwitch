import SwiftUI

struct MenuBarMenu: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var l10n = Localization.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack {
            // Provider list
            Menu(l10n.tr("Providers")) {
                ForEach(appState.providers) { provider in
                    Button {
                        appState.setActive(provider)
                    } label: {
                        HStack {
                            Text(provider.name)
                            if provider.id == appState.activeProviderId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Divider()

            // Start/Stop
            if let provider = appState.activeProvider, !provider.isOfficial {
                if appState.proxyRunning {
                    Button(l10n.tr("Stop Proxy")) {
                        appState.stopProxy()
                    }
                } else {
                    Button(l10n.tr("Start")) {
                        appState.startProxy()
                    }
                }
            } else {
                Button(l10n.tr("Start")) {
                    appState.startProxy()
                }
                .disabled(true)
            }

            Divider()

            // Show Window
            Button(l10n.tr("Show Window")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            // Quit
            Button(l10n.tr("Quit")) {
                appState.requestQuit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
