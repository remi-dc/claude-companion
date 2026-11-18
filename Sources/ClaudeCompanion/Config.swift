import Foundation

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
