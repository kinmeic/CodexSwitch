import SwiftUI

struct MenuBarMenu: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack {
            // Provider list
            Menu("Providers") {
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
                    Button("Stop Proxy") {
                        appState.stopProxy()
                    }
                } else {
                    Button("Start") {
                        appState.startProxy()
                    }
                }
            } else {
                Button("Start") {
                    appState.startProxy()
                }
                .disabled(true)
            }

            Divider()

            // Show Window
            Button("Show Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            // Quit
            Button("Quit") {
                appState.requestQuit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
