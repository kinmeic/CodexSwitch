import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared.quitRequested ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if AppState.shared.autoStartProxy {
            DispatchQueue.main.async {
                AppState.shared.startProxy()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if AppState.shared.proxyServer.running {
            AppState.shared.stopProxy()
        }
    }
}

@main
struct CodexSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // @ObservedObject rather than @StateObject: AppState.shared is a global
    // singleton whose lifecycle is not tied to this Scene. Using @StateObject
    // would semantically imply ownership that doesn't apply here.
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var l10n = Localization.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appState)
        } label: {
            // Menu bar icon: hollow c.square when stopped, filled c.square.fill
            // when the proxy is running.
            Image(systemName: appState.proxyRunning ? "c.square.fill" : "c.square")
                .font(.system(size: 22))
                .accessibilityLabel(appState.proxyRunning ? l10n.tr("CodexSwitch proxy running") : l10n.tr("CodexSwitch proxy stopped"))
        }

        Window("Codex Switch", id: "main") {
            MainWindow()
                .environmentObject(appState)
                .frame(minWidth: 750, minHeight: 500)
        }
        .defaultSize(width: 750, height: 550)
    }
}
