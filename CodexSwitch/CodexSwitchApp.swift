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
    @StateObject private var appState = AppState.shared

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
