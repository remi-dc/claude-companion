import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var config: CompanionConfig {
        didSet {
            guard !Demo.isOn else { return }
            config.save()
            Integration.writeActiveFile(activeAccount)
            Integration.writeWrapperData(config)
            if config.shortcuts != oldValue.shortcuts { registerShortcuts() }
            if config.notch != oldValue.notch { NotchController.shared.apply(self) }
        }
    }
    /// Shortcuts another app already uses (couldn't be registered).
    @Published var shortcutConflicts: [String] = []
    @Published var usage: [String: AccountUsage] = [:]
    @Published var recent: [HookMessage] = []
    @Published var isScanning = false
    @Published var lastScan: Date?
    @Published var lastError: String?
    /// Bumped to make views re-read on-disk status (hooks installed, login email).
    @Published var statusTick = 0
    @Published var notificationPermission: Notifier.Permission = .unknown
    /// Live state per Claude session, keyed by session id.
    @Published var sessions: [String: SessionStatus] = [:]
    /// Ticks while Claude is working, to animate the menu bar icon.
    @Published var iconFrame = 0
    /// Refreshed periodically so time-based states (done → idle) move on.
    @Published var now = Date()

    let notifier = Notifier()
    let updater = Updater()
    private let scanner = UsageScanner()
    private var timer: Timer?
    private var iconTimer: Timer?

    init() {
        if Demo.isOn {
            // Made-up data for README screenshots: no files, hooks, shortcuts or network.
            config = Demo.config()
            usage = Demo.usage()
            sessions = Demo.sessions()
            recent = Demo.recent()
            lastScan = Date()
            DispatchQueue.main.async { Demo.run(self) }
            return
        }
        config = CompanionConfig.load()
        config.save()
        Integration.writeActiveFile(activeAccount)
        Integration.writeWrapperData(config)
        Integration.writeHookShim()
        Integration.refreshInstalledWrappers()
        notifier.requestAuthorization()

        DistributedNotificationCenter.default().addObserver(
            forName: kHookNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let str = note.userInfo?["payload"] as? String,
                  let msg = try? JSONDecoder().decode(HookMessage.self, from: Data(str.utf8)) else { return }
            Task { @MainActor in self?.handle(msg) }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: kOpenWindowNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = note.userInfo?["window"] as? String ?? "dashboard"
            Task { @MainActor in
                guard let self else { return }
                WindowManager.shared.show(id, state: self)
            }
        }

        refreshUsage()
        refreshPermission()
        updater.start()
        registerShortcuts()
        DispatchQueue.main.async { NotchController.shared.apply(self) }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUsage(); self?.refreshPermission(); self?.now = Date() }
        }
        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mood == .working else { return }
                self.iconFrame &+= 1
            }
        }
    }

    // MARK: Flick's mood

    /// Sessions that still matter: needs-you for an hour, working for 30 min, done for 10 min.
    private func isLive(_ s: SessionStatus) -> Bool {
        let age = now.timeIntervalSince(s.date)
        switch s.mood {
        case .needs: return age < 3600
        case .working: return age < 1800
        case .done: return age < 600
        default: return false
        }
    }

    var liveSessions: [SessionStatus] {
        sessions.values.filter(isLive).sorted { $0.date > $1.date }
    }

    /// Flick's colors from Settings › Flick ("account" follows the active account).
    var flickPalette: FlickPalette {
        FlickPalette.named(config.flick.color, accountColor: config.color(for: activeAccount.id))
    }

    // MARK: Shortcuts

    func registerShortcuts() {
        shortcutConflicts = HotKeys.shared.register(config.shortcuts) { [weak self] action in
            self?.performShortcut(action)
        }
    }

    func performShortcut(_ action: String) {
        switch action {
        case "account1", "account2", "account3":
            let index = Int(action.suffix(1))! - 1
            guard index < config.accounts.count else { return }
            let account = config.accounts[index]
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) { activate(account.id) }
            presentAlert(id: "switch", title: config.friendlyMessages ? "Switched to \(account.name)" : "Active account: \(account.name)",
                         body: "New Claude sessions use this account.", mood: .done, account: account, sound: nil)
        case "popover":
            if config.notch.menuBarOn { HotKeys.togglePopover() } else { NotchController.shared.toggleExpanded() }
        case "sessions":
            WindowManager.shared.show("sessions", state: self)
        default:
            break
        }
    }

    var mood: FlickMood {
        if config.paused { return .sleep }
        let live = liveSessions
        if live.contains(where: { $0.mood == .needs }) { return .needs }
        if live.contains(where: { $0.mood == .working }) { return .working }
        if live.contains(where: { $0.mood == .done }) { return .done }
        if let last = recent.first?.date, now.timeIntervalSince(last) < 2 * 3600 { return .idle }
        return recent.isEmpty ? .idle : .sleep
    }

    /// The session Flick is talking about.
    var focusSession: SessionStatus? {
        let live = liveSessions
        return live.first { $0.mood == .needs } ?? live.first { $0.mood == .working } ?? live.first
    }

    func needsYou(_ accountID: String) -> Bool {
        liveSessions.contains { $0.accountID == accountID && $0.mood == .needs }
    }

    /// Flick's line (friendly) or a plain status line.
    var statusLine: (title: String, subtitle: String) {
        let friendly = config.friendlyMessages
        let s = focusSession
        let project = s?.project ?? ""
        let account = s.flatMap { config.account($0.accountID)?.name } ?? ""
        let working = liveSessions.filter { $0.mood == .working }.count
        switch mood {
        case .needs:
            return friendly ? ("\(account) needs a hand", "Waiting for your OK on \(project)")
                            : ("Permission needed", "\(account) · \(project)")
        case .working:
            let more = working > 1 ? " and \(working - 1) more" : ""
            return friendly ? ("On it!", "Working on \(project)\(more)")
                            : ("Working", "\(project)\(more) · \(account)")
        case .done:
            return friendly ? ("All done for now", "\(project) is ready for you")
                            : ("Finished", "\(project) · \(account)")
        case .sleep:
            if config.paused {
                return friendly ? ("Taking a nap", "Notifications are paused") : ("Paused", "Notifications are off")
            }
            return friendly ? ("Quiet for a while", "Wake me with a prompt") : ("Idle", "No recent activity")
        case .idle:
            return friendly ? ("All quiet", "Ready when you are") : ("Idle", "No active sessions")
        }
    }

    /// Notifications go to the notch (when it's on and set to) instead of macOS banners.
    var notchShowsNotifications: Bool {
        config.notch.notchOn && config.notch.notificationsInNotch && NotchController.shared.isOn
    }

    /// One place for usage alerts and confirmations: the notch, or a macOS notification.
    func presentAlert(id: String = UUID().uuidString, title: String, body: String, mood: FlickMood,
                      account: Account? = nil, sound: String? = "Tink") {
        if notchShowsNotifications {
            if let sound { Sounds.play(sound) }
            NotchController.shared.model.show(NotchAlert(id: id, title: title, subtitle: account?.name ?? "Claude Companion",
                                                         body: body, mood: mood))
        } else {
            notifier.postAlert(title: title, body: body, mood: mood, palette: flickPalette, account: account, sound: sound)
        }
    }

    /// Editors can't ask before a session starts, so show which account it's on, with a way to switch.
    private func remindAccount(for msg: HookMessage, key: String) {
        guard let account = config.account(msg.accountID) else { return }
        let others = config.accounts.filter { $0.id != account.id }
        if notchShowsNotifications {
            NotchController.shared.model.show(NotchAlert(
                id: "reminder-" + key, title: "This session is on \(account.name)",
                subtitle: account.loggedInEmail ?? msg.project,
                body: (config.friendlyMessages ? "Welcome back! " : "") + "Wrong account? Switch for your next conversation.",
                mood: .idle,
                actions: others.map { other in (other.name, { [weak self] in self?.activate(other.id) }) },
                stays: true))
            return
        }
        StickyNotes.shared.show(StickyNotes.Note(
            id: "reminder-" + key,
            title: "This session is on \(account.name)",
            subtitle: account.loggedInEmail ?? msg.project,
            body: (config.friendlyMessages ? "Welcome back! " : "") + "Wrong account? Switch, and your next conversation uses it.",
            mood: .idle, palette: flickPalette, location: nil,
            actions: others.map { other in
                (other.name, { [weak self] in
                    self?.activate(other.id)
                    StickyNotes.shared.dismiss("reminder-" + key)
                })
            }))
    }

    /// Brings the app hosting a session (Terminal, VS Code…) to the front.
    func open(_ session: SessionStatus) {
        Navigator.go(to: session.location)
    }

    var activeAccount: Account {
        config.account(config.activeAccountID) ?? config.accounts[0]
    }

    func activate(_ id: String) {
        config.activeAccountID = id
    }

    func handle(_ msg: HookMessage) {
        now = Date()
        let key = msg.sessionID ?? "\(msg.accountID)/\(msg.project)"
        // How long since Claude was last used (any account), for the "after a break" reminder.
        let lastEvent = UserDefaults.standard.object(forKey: "lastEventDate") as? Date ?? .distantPast
        UserDefaults.standard.set(msg.date, forKey: "lastEventDate")
        if msg.event == .started, sessions[key] == nil, config.reminderHours > 0,
           msg.date.timeIntervalSince(lastEvent) > Double(config.reminderHours) * 3600,
           msg.tty == nil,                                          // terminals already asked at launch
           msg.cwd.flatMap({ config.ruleAccount(for: $0) }) == nil { // a folder rule decided: nothing to confirm
            remindAccount(for: msg, key: key)
        }
        let mood: FlickMood
        switch msg.event {
        case .started: mood = .working
        case .permission: mood = .needs
        case .finished, .waiting: mood = .done
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            // A session "starts" with its first prompt after being idle or done.
            let previous = sessions[key]
            let continuing = previous.map { $0.mood == .working || $0.mood == .needs } ?? false
            let startedAt = continuing ? previous!.startedAt : msg.date
            sessions[key] = SessionStatus(id: key, accountID: msg.accountID, project: msg.project, mood: mood,
                                          date: msg.date, startedAt: startedAt, appBundleID: msg.appBundleID ?? sessions[key]?.appBundleID,
                                          location: SessionLocation(
                                            appBundleID: msg.appBundleID ?? sessions[key]?.location.appBundleID,
                                            cwd: msg.cwd ?? sessions[key]?.location.cwd,
                                            tty: msg.tty ?? sessions[key]?.location.tty,
                                            sessionID: msg.sessionID))
            if mood == .working { sessions[key]?.activity = msg.activity ?? (msg.event == .started && previous?.mood == .working ? previous?.activity : nil) }
            if msg.event == .finished { sessions[key]?.lastReply = msg.body }
        }
        if sessions.count > 50 {
            for k in sessions.sorted(by: { $0.value.date < $1.value.date }).prefix(sessions.count - 50).map(\.key) {
                sessions.removeValue(forKey: k)
            }
        }
        // Anything new from this session resolves its sticky card (e.g. you approved the permission).
        StickyNotes.shared.dismiss(key)
        if msg.event == .started { NotchController.shared.model.dismiss(key) }
        guard msg.event != .started else { return }

        recent.insert(msg, at: 0)
        if recent.count > 30 { recent.removeLast(recent.count - 30) }
        let account = config.account(msg.accountID)
        guard !config.paused, account?.notificationsEnabled != false else { return }
        if notchShowsNotifications {
            if let account { Sounds.play(account.sound(for: msg.event)) }
            let mood: FlickMood = msg.event == .permission ? .needs : .done
            NotchController.shared.model.show(NotchAlert(
                id: key,
                title: msg.event == .permission ? "\(account?.name ?? "Claude") needs a hand"
                     : msg.event == .finished ? "\(msg.project) is ready" : "Waiting for you · \(msg.project)",
                subtitle: "\(account?.name ?? msg.accountID) · \(msg.project)",
                body: config.showMessagePreview ? msg.body : nil,
                mood: mood, location: msg.location,
                copyText: msg.event == .finished ? msg.body : nil,
                stays: msg.event == .permission))
        } else if config.isSticky(msg.event) {
            if let account { Sounds.play(account.sound(for: msg.event)) }
            StickyNotes.shared.show(StickyNotes.Note(
                id: key, title: "\(msg.event.title) · \(msg.project)", subtitle: account?.name ?? msg.accountID,
                body: config.showMessagePreview ? msg.body : "",
                mood: msg.event == .permission ? .needs : .done, palette: flickPalette, location: msg.location))
        } else {
            notifier.post(msg, account: account, preview: config.showMessagePreview, palette: flickPalette)
        }
        // A finished turn usually means new usage on disk.
        if msg.event == .finished { refreshUsage() }
    }

    func sendTest(_ event: HookEvent, account: Account) {
        let body: String
        switch event {
        case .finished: body = "All tests pass. I refactored the parser and updated the README."
        case .permission: body = "Claude needs your permission to use Bash"
        case .waiting: body = "Claude is waiting for your input"
        case .started: body = ""
        }
        handle(HookMessage(accountID: account.id, event: event, project: "test-project", body: body))
    }

    func refreshPermission() {
        notifier.permission { [weak self] p in self?.notificationPermission = p }
    }

    func refreshUsage() {
        if Demo.isOn { return }
        guard !isScanning else { return }
        isScanning = true
        scanner.scan(config.accounts) { [weak self] result in
            guard let self else { return }
            self.usage = result
            self.isScanning = false
            self.lastScan = Date()
            AlertsEngine.evaluate(self)
        }
    }

    // MARK: Account editing

    func update(_ account: Account) {
        guard let i = config.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        config.accounts[i] = account
    }

    func addAccount() {
        var n = config.accounts.count + 1
        while config.accounts.contains(where: { $0.id == "account\(n)" }) { n += 1 }
        config.accounts.append(.make(id: "account\(n)", name: "Account \(n)", symbol: "person.crop.circle",
                                     dir: "~/.claude-account\(n)", finished: "Glass", permission: "Sosumi", waiting: "Tink"))
    }

    func removeAccount(_ id: String) {
        guard config.accounts.count > 1 else { return }
        config.accounts.removeAll { $0.id == id }
        if config.activeAccountID == id { config.activeAccountID = config.accounts[0].id }
    }

    // MARK: Integration

    func installAllHooks() {
        lastError = nil
        Integration.writeHookShim()
        for a in config.accounts {
            do { try Integration.installHooks(for: a) } catch { lastError = error.localizedDescription }
        }
        statusTick += 1
    }

    func removeAllHooks() {
        lastError = nil
        for a in config.accounts {
            do { try Integration.removeHooks(for: a) } catch { lastError = error.localizedDescription }
        }
        statusTick += 1
    }

    func setVSCode(_ path: String, enabled: Bool) {
        lastError = nil
        do {
            if enabled { try Integration.configureVSCode(path) } else { try Integration.unconfigureVSCode(path) }
        } catch { lastError = error.localizedDescription }
        statusTick += 1
    }

    func installShellIntegration() {
        lastError = nil
        Integration.installWrapper()
        do { try Integration.addToZshrc() } catch { lastError = error.localizedDescription }
        statusTick += 1
    }
}

struct SessionStatus: Identifiable, Hashable {
    var id: String
    var accountID: String
    var project: String
    var mood: FlickMood
    var date: Date
    var startedAt: Date
    var appBundleID: String?
    var location: SessionLocation
    /// What Claude is doing right now (live activity), while working.
    var activity: String? = nil
    /// Claude's last reply, for the "done" preview.
    var lastReply: String? = nil
}
