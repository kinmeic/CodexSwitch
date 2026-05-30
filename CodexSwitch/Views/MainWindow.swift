import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        DetailView()
            .navigationTitle("Codex Switch")
            .frame(minWidth: 700, minHeight: 450)
    }
}
