import SwiftUI

struct CompanionApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { state.config.notch.menuBarOn || Demo.isOn }, set: { _ in })) {
            MenuBarView()
                .environmentObject(state)
                .environmentObject(state.updater)
        } label: {
            let needs = state.liveSessions.first { $0.mood == .needs }
            Image(nsImage: MenuBarIcon.image(
                mood: state.mood, paused: state.config.paused, frame: state.iconFrame,
                badge: needs.map { NSColor(state.config.color(for: $0.accountID)) },
                accountDot: state.config.showAccountInMenuBar ? NSColor(state.config.color(for: state.activeAccount.id)) : nil))
        }
        .menuBarExtraStyle(.window)
    }
}
