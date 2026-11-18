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

    let notifier = Notifier()
    private let scanner = UsageScanner()
    private var timer: Timer?

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
            Task { @MainActor in self?.refreshUsage(); self?.refreshPermission() }
        }
    }

    var activeAccount: Account {
        config.account(config.activeAccountID) ?? config.accounts[0]
    }

    func activate(_ id: String) {
        config.activeAccountID = id
    }

    func handle(_ msg: HookMessage) {
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
