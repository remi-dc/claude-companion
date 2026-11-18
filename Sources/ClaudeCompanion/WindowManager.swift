import AppKit
import SwiftUI

let kOpenWindowNotification = Notification.Name("dev.claudecompanion.open")

/// AppKit-hosted windows, so they can be opened from anywhere (menu, CLI, notifications).
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func show(_ id: String, state: AppState) {
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let (title, size, view): (String, NSSize, AnyView)
        switch id {
        case "settings":
            (title, size, view) = ("Claude Companion Settings", NSSize(width: 720, height: 540),
                                   AnyView(SettingsView().environmentObject(state).tint(Ember.accent)))
        case "popover":
            // Same view as the menu bar popover, in a window (handy for screenshots and demos).
            (title, size, view) = ("Claude Companion", NSSize(width: 348, height: 640),
                                   AnyView(MenuBarView().environmentObject(state).background(.regularMaterial)))
        default:
            (title, size, view) = ("Usage Dashboard", NSSize(width: 940, height: 760),
                                   AnyView(DashboardView().environmentObject(state).tint(Ember.accent)))
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName(title)
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
