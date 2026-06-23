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

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appState)
        } label: {
            Image(appState.proxyRunning ? "MenuBarIconActive" : "MenuBarIcon")
                .renderingMode(.original)
                .id(appState.proxyRunning)
                .accessibilityLabel(appState.proxyRunning ? "CodexSwitch proxy running" : "CodexSwitch proxy stopped")
        }

        Window("Codex Switch", id: "main") {
            MainWindow()
                .environmentObject(appState)
                .frame(minWidth: 750, minHeight: 500)
        }
        .defaultSize(width: 750, height: 550)
    }
}
