import AppKit
import SwiftUI

/// Something to show in the notch instead of a macOS notification.
struct NotchAlert: Identifiable {
    let id: String
    var title: String
    var subtitle: String
    var body: String? = nil
    var mood: FlickMood
    var location: SessionLocation? = nil
    var actions: [(String, () -> Void)] = []
    var copyText: String? = nil
    /// The account it's about, shown by name in the folded notch.
    var accountID: String? = nil
    /// Stays until resolved (permission requests); otherwise folds back after a few seconds.
    var stays = false
}

enum NotchTab: String, CaseIterable, Identifiable {
    case claude, music, calendar, shelf, clipboard
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .claude: return "flame.fill"
        case .music: return "music.note"
        case .calendar: return "calendar"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "doc.on.clipboard"
        }
    }
}

/// The real notch (or, on screens without one, a pill in the menu bar).
struct NotchGeometry: Equatable {
    var hasNotch: Bool
    var notchWidth: CGFloat
    var height: CGFloat
    var screenFrame: CGRect

    static func of(_ screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return NotchGeometry(hasNotch: true, notchWidth: screen.frame.width - l.width - r.width,
                                 height: top, screenFrame: screen.frame)
        }
        let bar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(hasNotch: false, notchWidth: 120, height: bar, screenFrame: screen.frame)
    }
}

/// Size and shape of the black island for the current state.
struct NotchLayout: Equatable {
    enum Kind: Equatable { case idle, working, alert, alertCompact, expanded }
    var kind: Kind
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat

    @MainActor
    static func compute(_ model: NotchModel, _ state: AppState) -> NotchLayout {
        let g = model.geometry
        let base = g.notchWidth
        if model.expanded {
            // Only as tall as the tab needs: no big black void.
            let body: CGFloat
            switch model.tab {
            case .claude: body = 196
            case .music: body = 150
            case .calendar: body = 176
            case .shelf: body = 214
            case .clipboard: body = 236
            }
            return NotchLayout(kind: .expanded, width: max(base + 300, 700), height: g.height + body, radius: 28)
        }
        // Compact states never go below the menu bar, so they never cover your windows.
        let compactHeight = g.hasNotch ? g.height : g.height - 4
        if model.alert != nil {
            if model.alertCollapsed { return NotchLayout(kind: .alertCompact, width: base + 330, height: compactHeight, radius: 12) }
            return NotchLayout(kind: .alert, width: max(base + 260, 560), height: g.height + 100, radius: 26)
        }
        if state.liveSessions.contains(where: { $0.mood == .working }) {
            return NotchLayout(kind: .working, width: base + 330, height: compactHeight, radius: 12)
        }
        return NotchLayout(kind: .idle, width: base + (g.hasNotch ? 150 : 110), height: g.hasNotch ? g.height : g.height - 4, radius: g.hasNotch ? 10 : 12)
    }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var expanded = false
    @Published var tab: NotchTab = .claude
    @Published private(set) var alert: NotchAlert?
    /// A lasting alert (permission) folds into the menu bar after a few seconds instead of covering your windows.
    @Published private(set) var alertCollapsed = false
    /// The pointer is on the card: keep it (no countdown, no tabs taking over).
    @Published var hoveringAlert = false
    private var unfoldedByHover = false
    private var collapseTask: DispatchWorkItem?
    @Published var isPrivate = false
    @Published var geometry = NotchGeometry(hasNotch: false, notchWidth: 120, height: 24, screenFrame: .zero)
    private var queue: [NotchAlert] = []
    private var dismissTask: DispatchWorkItem?

    func show(_ a: NotchAlert) {
        queue.removeAll { $0.id == a.id }
        if alert?.id == a.id || alert == nil {
            present(a)
        } else if a.stays && alert?.stays == false {
            if let current = alert { queue.insert(current, at: 0) }
            present(a)                      // something that needs you jumps the queue
        } else {
            queue.append(a)
        }
    }

    func dismiss(_ id: String) {
        queue.removeAll { $0.id == id }
        guard alert?.id == id else { return }
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { alert = nil }
        if !queue.isEmpty {
            let next = queue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.present(next) }
        }
    }

    private func present(_ a: NotchAlert) {
        dismissTask?.cancel()
        collapseTask?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { alert = a; alertCollapsed = false }
        guard a.stays else { scheduleDismiss(a.id, after: 8); return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.alert?.id == a.id, !self.expanded else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self.alertCollapsed = true }
        }
        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: task)
    }

    /// Hovering a folded permission request opens the card again (not the tabs).
    func unfold() {
        guard alert != nil, alertCollapsed else { return }
        collapseTask?.cancel()
        unfoldedByHover = true
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { alertCollapsed = false }
    }

    /// Fold it back a moment after the pointer leaves, if hovering is what opened it.
    func refoldSoon() {
        guard unfoldedByHover, let a = alert, a.stays, !alertCollapsed else { return }
        unfoldedByHover = false
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.alert?.id == a.id, !self.hoveringAlert else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self.alertCollapsed = true }
        }
        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    private func scheduleDismiss(_ id: String, after seconds: Double) {
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Wait while you're looking at it.
            if self.expanded || self.hoveringAlert { self.scheduleDismiss(id, after: 3) } else { self.dismiss(id) }
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }
}

/// Owns the notch window: placement, hover to open, click-through outside the island.
@MainActor
final class NotchController {
    static let shared = NotchController()

    let model = NotchModel()
    let music = MusicController()
    let calendar = CalendarProvider()
    let shelf = ShelfStore()
    let clipboard = ClipboardWatcher()

    private var panel: NSPanel?
    private weak var state: AppState?
    private var monitors: [Any] = []
    private var hoverTask: DispatchWorkItem?
    private var closeTask: DispatchWorkItem?
    private var screenObserver: Any?
    private var mirrorTimer: Timer?
    private let panelSize = NSSize(width: 860, height: 440)

    var isOn: Bool { panel != nil }
    var windowNumber: Int? { panel?.windowNumber }

    func apply(_ state: AppState) {
        self.state = state
        let settings = state.config.notch
        clipboard.setEnabled(settings.notchOn && settings.clipboardTab && !Demo.isOn)
        if settings.notchOn { start(state) } else { stop() }
    }

    func toggleExpanded() {
        guard isOn else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { model.expanded.toggle() }
    }

    private func start(_ state: AppState) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.ignoresMouseEvents = true
            p.becomesKeyOnlyIfNeeded = true
            p.contentView = FirstClickHostingView(rootView: NotchRootView()
                .modifier(FlickThemed())
                .environmentObject(state).environmentObject(model).environmentObject(music)
                .environmentObject(calendar).environmentObject(shelf).environmentObject(clipboard))
            panel = p
            installMonitors()
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.place(); self?.checkMirroring() }
            }
            mirrorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkMirroring() }
            }
        }
        place()
        checkMirroring()
        panel?.orderFrontRegardless()
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        mirrorTimer?.invalidate()
        mirrorTimer = nil
        panel?.orderOut(nil)
        panel = nil
        model.expanded = false
    }

    // MARK: Placement

    private func targetScreen() -> NSScreen? {
        if state?.config.notch.screen == "pointer" {
            let p = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) { return s }
        }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func place() {
        guard let panel, let screen = targetScreen() else { return }
        model.geometry = NotchGeometry.of(screen)
        panel.setFrame(NSRect(x: screen.frame.midX - panelSize.width / 2, y: screen.frame.maxY - panelSize.height,
                              width: panelSize.width, height: panelSize.height), display: true)
    }

    /// Hide private things while the display is mirrored (presenting, AirPlay…).
    private func checkMirroring() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let mirrored = ids.contains { CGDisplayIsInMirrorSet($0) != 0 }
        let priv = mirrored && (state?.config.notch.privateWhenMirroring ?? true)
        if model.isPrivate != priv { model.isPrivate = priv }
    }

    // MARK: Hover

    private func islandRect() -> NSRect {
        guard let state else { return .zero }
        let layout = NotchLayout.compute(model, state)
        let f = model.geometry.screenFrame
        return NSRect(x: f.midX - layout.width / 2, y: f.maxY - layout.height, width: layout.width, height: layout.height)
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved(dragging: event.type == .leftMouseDragged) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    private func mouseMoved(dragging: Bool) {
        guard let panel, !Demo.isOn else { return }
        let p = NSEvent.mouseLocation
        if state?.config.notch.screen == "pointer", !model.expanded,
           let s = NSScreen.screens.first(where: { $0.frame.contains(p) }), s.frame != model.geometry.screenFrame {
            place()
        }
        let rect = islandRect()
        panel.ignoresMouseEvents = !rect.contains(p)
        let near = rect.insetBy(dx: -6, dy: -6).contains(p)

        // A card is showing: hovering it keeps it (and unfolds a folded one); it never turns into the tabs.
        if model.alert != nil && !model.expanded {
            hoverTask?.cancel()
            hoverTask = nil
            if model.hoveringAlert != near { model.hoveringAlert = near }
            if near { model.unfold() } else { model.refoldSoon() }
            return
        }
        if model.hoveringAlert { model.hoveringAlert = false }

        if !model.expanded {
            closeTask?.cancel()
            if near, hoverTask == nil {
                // Dragging files onto the notch opens the shelf.
                let files = dragging && (NSPasteboard(name: .drag).types ?? []).contains(.fileURL)
                let task = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.hoverTask = nil
                    guard self.islandRect().insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) else { return }
                    if files, self.state?.config.notch.shelfTab == true { self.model.tab = .shelf }
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { self.model.expanded = true }
                }
                hoverTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
            } else if !near {
                hoverTask?.cancel()
                hoverTask = nil
            }
        } else if !rect.insetBy(dx: -14, dy: -14).contains(p) {
            if closeTask == nil {
                let task = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.closeTask = nil
                    guard !self.islandRect().insetBy(dx: -14, dy: -14).contains(NSEvent.mouseLocation) else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self.model.expanded = false }
                }
                closeTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
            }
        } else {
            closeTask?.cancel()
            closeTask = nil
        }
    }
}

/// The notch never takes focus, so without this the first click on a button only "activates"
/// the window instead of pressing the button (e.g. Clear seemed to do nothing).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
