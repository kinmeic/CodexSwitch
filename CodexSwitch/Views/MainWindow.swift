import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        DetailView()
            .frame(minWidth: 700, minHeight: 450)
    }
}
