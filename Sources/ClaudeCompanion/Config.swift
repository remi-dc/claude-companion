import Foundation
import CoreGraphics

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let companionDir = home + "/.claude-companion"
    static let binDir = companionDir + "/bin"
    static let configFile = companionDir + "/config.json"
    /// Read by the `claude` wrapper on every launch to pick the account.
    static let activeFile = companionDir + "/active-config-dir"
    static let hookShim = binDir + "/claude-companion-hook"
    static let wrapper = binDir + "/claude"
    static let defaultConfigDir = home + "/.claude"

    static func ensureDir(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}

/// The three moments Claude Code can tell us about.
enum HookEvent: String, Codable, CaseIterable, Identifiable {
    case finished, permission, waiting
    /// You sent a prompt; Claude is working. Drives Flick, never notifies.
    case started
    var id: String { rawValue }

    /// The events that produce a notification and have a sound.
    static let notifiable: [HookEvent] = [.finished, .permission, .waiting]

    var title: String {
        switch self {
        case .finished: return "Finished"
        case .permission: return "Needs permission"
        case .waiting: return "Waiting for input"
        case .started: return "Working"
        }
    }

    var symbol: String {
        switch self {
        case .finished: return "checkmark.circle.fill"
        case .permission: return "hand.raised.fill"
        case .waiting: return "ellipsis.bubble.fill"
        case .started: return "flame.fill"
        }
    }
}

struct Account: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var configDir: String
    var sounds: [String: String]
    var notificationsEnabled: Bool
    /// Browser (and profile) Claude's sign-in page opens in for this account; nil = system default.
    var loginBrowser: String? = nil

    var expandedConfigDir: String {
        var p = (configDir as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
    var isDefaultDir: Bool { expandedConfigDir == Paths.defaultConfigDir }
    var settingsPath: String { expandedConfigDir + "/settings.json" }
    var projectsDir: String { expandedConfigDir + "/projects" }
    /// Claude Code keeps login/profile info here (outside the dir for the default account).
    var globalConfigPath: String {
        isDefaultDir ? Paths.home + "/.claude.json" : expandedConfigDir + "/.claude.json"
    }

    func sound(for e: HookEvent) -> String { sounds[e.rawValue] ?? "None" }

    /// The signed-in email, if Claude Code has logged in under this config dir.
    var loggedInEmail: String? {
        guard let data = FileManager.default.contents(atPath: globalConfigPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["oauthAccount"] as? [String: Any] else { return nil }
        return oauth["emailAddress"] as? String
    }

    static func make(id: String, name: String, symbol: String, dir: String,
                     finished: String, permission: String, waiting: String) -> Account {
        Account(id: id, name: name, symbol: symbol, configDir: dir,
                sounds: ["finished": finished, "permission": permission, "waiting": waiting],
                notificationsEnabled: true)
    }
}

struct CompanionConfig: Codable {
    var accounts: [Account]
    var activeAccountID: String
    var paused: Bool
    var showMessagePreview: Bool
    /// Flick speaks in short friendly lines instead of plain status text.
    var friendlyMessages: Bool
    var alerts = AlertSettings()
    /// Action id → shortcut. A missing entry means the shortcut is off.
    var shortcuts: [String: Shortcut] = Shortcut.defaults
    var knownShortcutActions: [String] = Shortcut.actions.map(\.id)
    var flick = FlickSettings()
    /// Event → "banner" (disappears) or "sticky" (stays on screen until dismissed or resolved).
    var notificationStyles: [String: String] = ["permission": "sticky"]

    func isSticky(_ event: HookEvent) -> Bool { notificationStyles[event.rawValue] == "sticky" }
    /// Projects inside these folders always use the given account (longest match wins).
    var folderRules: [FolderRule] = []
    /// After this many hours without Claude activity, confirm the account when a session starts. 0 = off.
    var reminderHours = 4
    /// A dot in the active account's color on the menu bar icon.
    var showAccountInMenuBar = true
    /// How the menu bar shows the active account: "name" (e.g. "School"), "dot" (its color) or "off".
    var menuBarAccount = "name"
    var notch = NotchSettings()
    var phone = PhoneSettings()

    /// The account a folder rule assigns to `path`, if any.
    func ruleAccount(for path: String) -> Account? {
        folderRules
            .filter { r in let f = r.expandedFolder; return path == f || path.hasPrefix(f + "/") }
            .max { $0.expandedFolder.count < $1.expandedFolder.count }
            .flatMap { account($0.accountID) }
    }

    init(accounts: [Account], activeAccountID: String, paused: Bool, showMessagePreview: Bool, friendlyMessages: Bool) {
        self.accounts = accounts
        self.activeAccountID = activeAccountID
        self.paused = paused
        self.showMessagePreview = showMessagePreview
        self.friendlyMessages = friendlyMessages
    }

    /// Tolerant decoding: settings added in later versions fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CompanionConfig.defaults
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? d.accounts
        activeAccountID = try c.decodeIfPresent(String.self, forKey: .activeAccountID) ?? d.activeAccountID
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        showMessagePreview = try c.decodeIfPresent(Bool.self, forKey: .showMessagePreview) ?? true
        friendlyMessages = try c.decodeIfPresent(Bool.self, forKey: .friendlyMessages) ?? true
        alerts = (try? c.decodeIfPresent(AlertSettings.self, forKey: .alerts)) ?? AlertSettings()
        shortcuts = (try? c.decodeIfPresent([String: Shortcut].self, forKey: .shortcuts)) ?? Shortcut.defaults
        // Give shortcuts added in later versions their default, without re-enabling ones you turned off.
        let known = (try? c.decodeIfPresent([String].self, forKey: .knownShortcutActions))
            ?? ["account1", "account2", "account3", "popover", "sessions"]
        for (id, s) in Shortcut.defaults where !known.contains(id) && shortcuts[id] == nil { shortcuts[id] = s }
        knownShortcutActions = Shortcut.actions.map(\.id)
        flick = (try? c.decodeIfPresent(FlickSettings.self, forKey: .flick)) ?? FlickSettings()
        notificationStyles = (try? c.decodeIfPresent([String: String].self, forKey: .notificationStyles)) ?? ["permission": "sticky"]
        folderRules = (try? c.decodeIfPresent([FolderRule].self, forKey: .folderRules)) ?? []
        reminderHours = (try? c.decodeIfPresent(Int.self, forKey: .reminderHours)) ?? 4
        showAccountInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showAccountInMenuBar)) ?? true
        menuBarAccount = (try? c.decodeIfPresent(String.self, forKey: .menuBarAccount)) ?? (showAccountInMenuBar ? "name" : "off")
        notch = (try? c.decodeIfPresent(NotchSettings.self, forKey: .notch)) ?? NotchSettings()
        phone = (try? c.decodeIfPresent(PhoneSettings.self, forKey: .phone)) ?? PhoneSettings()
    }

    static var defaults: CompanionConfig {
        CompanionConfig(
            accounts: [
                .make(id: "personal", name: "Personal", symbol: "person.fill", dir: "~/.claude",
                      finished: "Glass", permission: "Sosumi", waiting: "Tink"),
                .make(id: "work", name: "Work", symbol: "briefcase.fill", dir: "~/.claude-work",
                      finished: "Hero", permission: "Basso", waiting: "Pop"),
                .make(id: "backup", name: "Backup", symbol: "externaldrive.fill", dir: "~/.claude-backup",
                      finished: "Purr", permission: "Funk", waiting: "Bottle"),
            ],
            activeAccountID: "personal",
            paused: false,
            showMessagePreview: true,
            friendlyMessages: true
        )
    }

    static func load() -> CompanionConfig {
        guard let data = FileManager.default.contents(atPath: Paths.configFile),
              let cfg = try? JSONDecoder().decode(CompanionConfig.self, from: data),
              !cfg.accounts.isEmpty else { return .defaults }
        return cfg
    }

    func save() {
        Paths.ensureDir(Paths.companionDir)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: URL(fileURLWithPath: Paths.configFile), options: .atomic)
        }
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
}

// MARK: Alerts

struct AlertSettings: Codable, Equatable {
    /// Monthly budget alerts (80% and 100%), per account in USD. 0 = no budget.
    var budgetEnabled = false
    var budgets: [String: Double] = [:]
    /// The current 5-hour window has used more than `windowThreshold` dollars.
    var windowEnabled = false
    var windowThreshold: Double = 30
    /// A busy 5-hour window just reset.
    var resetEnabled = true
    /// A summary of the day at `summaryHour`.
    var summaryEnabled = false
    var summaryHour = 18

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertSettings()
        budgetEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .budgetEnabled)) ?? d.budgetEnabled
        budgets = (try? c.decodeIfPresent([String: Double].self, forKey: .budgets)) ?? d.budgets
        windowEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .windowEnabled)) ?? d.windowEnabled
        windowThreshold = (try? c.decodeIfPresent(Double.self, forKey: .windowThreshold)) ?? d.windowThreshold
        resetEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .resetEnabled)) ?? d.resetEnabled
        summaryEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .summaryEnabled)) ?? d.summaryEnabled
        summaryHour = (try? c.decodeIfPresent(Int.self, forKey: .summaryHour)) ?? d.summaryHour
    }
}

// MARK: Shortcuts

/// A global keyboard shortcut, stored with Carbon key code and modifiers.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let actions: [(id: String, title: String)] = [
        ("account1", "Switch to account 1"), ("account2", "Switch to account 2"), ("account3", "Switch to account 3"),
        ("popover", "Open Claude Companion"), ("sessions", "Show sessions"),
        ("command", "Ask Claude (command bar)"), ("projects", "Projects and history"),
    ]

    // Carbon modifier bits: cmd 256, shift 512, option 2048, control 4096. Key codes: 1→18, 2→19, 3→20, C→8, S→1.
    static let defaults: [String: Shortcut] = [
        "account1": Shortcut(keyCode: 18, modifiers: 2048 | 256, display: "⌥⌘1"),
        "account2": Shortcut(keyCode: 19, modifiers: 2048 | 256, display: "⌥⌘2"),
        "account3": Shortcut(keyCode: 20, modifiers: 2048 | 256, display: "⌥⌘3"),
        "popover": Shortcut(keyCode: 8, modifiers: 2048 | 256, display: "⌥⌘C"),
        "sessions": Shortcut(keyCode: 1, modifiers: 2048 | 256, display: "⌥⌘S"),
        "command": Shortcut(keyCode: 40, modifiers: 2048 | 256, display: "⌥⌘K"),
        "projects": Shortcut(keyCode: 35, modifiers: 2048 | 256, display: "⌥⌘P"),
    ]
}

// MARK: Flick

struct FlickSettings: Codable, Equatable {
    /// "ember", "glacier", "mint" or "account" (the active account's color).
    var color = "ember"
    /// Size in the popover: "small", "medium", "large".
    var size = "medium"
    /// Keep Flick still even without macOS's Reduce Motion.
    var calm = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? "ember"
        size = (try? c.decodeIfPresent(String.self, forKey: .size)) ?? "medium"
        calm = (try? c.decodeIfPresent(Bool.self, forKey: .calm)) ?? false
    }

    var popoverSize: CGFloat {
        switch size { case "small": return 42; case "large": return 68; default: return 54 }
    }
}

// MARK: Folder rules

struct FolderRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var folder: String
    var accountID: String

    var expandedFolder: String {
        var p = (folder as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

// MARK: Notch

struct NotchSettings: Codable, Equatable {
    /// "menubar", "notch" or "both".
    var presentation = "menubar"
    /// When the notch is on, show notifications and alerts there instead of macOS banners (sounds still play).
    var notificationsInNotch = true
    /// "builtin" (the screen with the notch) or "pointer" (the screen under the mouse).
    var screen = "builtin"
    /// Hide projects, messages, clipboard and shelf while the display is mirrored.
    var privateWhenMirroring = true
    /// Show what Claude is doing right now (editing a file, running a command…).
    var liveActivity = true
    var musicTab = true
    var calendarTab = true
    var shelfTab = true
    var clipboardTab = true

    var notchOn: Bool { presentation != "menubar" }
    var menuBarOn: Bool { presentation != "notch" }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotchSettings()
        presentation = (try? c.decodeIfPresent(String.self, forKey: .presentation)) ?? d.presentation
        notificationsInNotch = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsInNotch)) ?? d.notificationsInNotch
        screen = (try? c.decodeIfPresent(String.self, forKey: .screen)) ?? d.screen
        privateWhenMirroring = (try? c.decodeIfPresent(Bool.self, forKey: .privateWhenMirroring)) ?? d.privateWhenMirroring
        liveActivity = (try? c.decodeIfPresent(Bool.self, forKey: .liveActivity)) ?? d.liveActivity
        musicTab = (try? c.decodeIfPresent(Bool.self, forKey: .musicTab)) ?? d.musicTab
        calendarTab = (try? c.decodeIfPresent(Bool.self, forKey: .calendarTab)) ?? d.calendarTab
        shelfTab = (try? c.decodeIfPresent(Bool.self, forKey: .shelfTab)) ?? d.shelfTab
        clipboardTab = (try? c.decodeIfPresent(Bool.self, forKey: .clipboardTab)) ?? d.clipboardTab
    }
}

// MARK: Phone

/// Push notifications to your phone through ntfy (https://ntfy.sh, or your own server).
struct PhoneSettings: Codable, Equatable {
    var enabled = false
    var server = "https://ntfy.sh"
    /// A long random topic: anyone who knows it can read the messages, so it acts as a password.
    var topic = "claude-companion-" + String((0..<20).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! })
    /// Only when you're away from the Mac (idle or locked).
    var onlyWhenAway = true
    var awayMinutes = 5
    var permission = true
    var finished = true
    var waiting = false
    var alerts = true
    /// Include Claude's message text (it then passes through the ntfy server).
    var includeText = false

    var topicURL: URL? {
        URL(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/" + topic)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PhoneSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        server = (try? c.decodeIfPresent(String.self, forKey: .server)) ?? d.server
        topic = (try? c.decodeIfPresent(String.self, forKey: .topic)) ?? d.topic
        onlyWhenAway = (try? c.decodeIfPresent(Bool.self, forKey: .onlyWhenAway)) ?? d.onlyWhenAway
        awayMinutes = (try? c.decodeIfPresent(Int.self, forKey: .awayMinutes)) ?? d.awayMinutes
        permission = (try? c.decodeIfPresent(Bool.self, forKey: .permission)) ?? d.permission
        finished = (try? c.decodeIfPresent(Bool.self, forKey: .finished)) ?? d.finished
        waiting = (try? c.decodeIfPresent(Bool.self, forKey: .waiting)) ?? d.waiting
        alerts = (try? c.decodeIfPresent(Bool.self, forKey: .alerts)) ?? d.alerts
        includeText = (try? c.decodeIfPresent(Bool.self, forKey: .includeText)) ?? d.includeText
    }
}
