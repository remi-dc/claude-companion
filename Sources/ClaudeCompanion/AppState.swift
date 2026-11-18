import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var config: CompanionConfig {
        didSet {
            config.save()
            Integration.writeActiveFile(activeAccount)
        }
    }
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
    private let scanner = UsageScanner()
    private var timer: Timer?
    private var iconTimer: Timer?

    init() {
        config = CompanionConfig.load()
        config.save()
        Integration.writeActiveFile(activeAccount)
        Integration.writeHookShim()
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

    /// Brings the app hosting a session (Terminal, VS Code…) to the front.
    func open(_ session: SessionStatus) {
        guard let id = session.appBundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        app.activate()
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
        let mood: FlickMood
        switch msg.event {
        case .started: mood = .working
        case .permission: mood = .needs
        case .finished, .waiting: mood = .done
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            sessions[key] = SessionStatus(id: key, accountID: msg.accountID, project: msg.project, mood: mood,
                                          date: msg.date, appBundleID: msg.appBundleID ?? sessions[key]?.appBundleID)
        }
        if sessions.count > 50 {
            for k in sessions.sorted(by: { $0.value.date < $1.value.date }).prefix(sessions.count - 50).map(\.key) {
                sessions.removeValue(forKey: k)
            }
        }
        guard msg.event != .started else { return }

        recent.insert(msg, at: 0)
        if recent.count > 30 { recent.removeLast(recent.count - 30) }
        let account = config.account(msg.accountID)
        guard !config.paused, account?.notificationsEnabled != false else { return }
        notifier.post(msg, account: account, preview: config.showMessagePreview)
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
        guard !isScanning else { return }
        isScanning = true
        scanner.scan(config.accounts) { [weak self] result in
            guard let self else { return }
            self.usage = result
            self.isScanning = false
            self.lastScan = Date()
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
    var appBundleID: String?
}
