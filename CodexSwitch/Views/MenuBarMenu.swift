import SwiftUI

struct MenuBarMenu: View {
    @EnvironmentObject private var appState: AppState

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
                showMainWindow()
            }

            Divider()

            // Quit
            Button("Quit") {
                appState.requestQuit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Codex Switch" }) {
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
