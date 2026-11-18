import SwiftUI

struct CompanionApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.config.paused ? "bell.slash" : state.activeAccount.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}
