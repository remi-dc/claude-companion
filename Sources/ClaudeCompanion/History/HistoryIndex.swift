import AppKit
import Foundation

/// One Claude Code conversation, read from its transcript.
struct Conversation: Identifiable, Hashable {
    let id: String              // Claude Code session id
    let accountID: String
    let project: String         // folder the session ran in
    let title: String
    let firstDate: Date
    let lastDate: Date
    let messageCount: Int
    let file: URL
    /// Lowercased text of your messages and Claude's replies, for search (capped).
    let searchText: String

    var projectName: String { (project as NSString).lastPathComponent }
}

struct ProjectSummary: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    var accountIDs: [String]
    var lastDate: Date
    var conversations: Int
}

/// Indexes conversations across accounts in the background. Files are re-read only when they change.
@MainActor
final class HistoryIndex: ObservableObject {
    static let shared = HistoryIndex()

    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var lastIndexed: Date?

    private var cache: [String: (stamp: String, conv: Conversation?)] = [:]
    private let queue = DispatchQueue(label: "history-index", qos: .utility)
    nonisolated static let lookbackDays = 90

    var projects: [ProjectSummary] {
        var byPath: [String: ProjectSummary] = [:]
        for c in conversations {
            var p = byPath[c.project] ?? ProjectSummary(path: c.project, accountIDs: [], lastDate: .distantPast, conversations: 0)
            if !p.accountIDs.contains(c.accountID) { p.accountIDs.append(c.accountID) }
            p.lastDate = max(p.lastDate, c.lastDate)
            p.conversations += 1
            byPath[c.project] = p
        }
        return byPath.values.sorted { $0.lastDate > $1.lastDate }
    }

    func refresh(accounts: [Account]) {
        if Demo.isOn { conversations = Demo.conversations(); return }
        guard !isIndexing else { return }
        isIndexing = true
        let cache = self.cache
        queue.async {
            var newCache = cache
            var result: [Conversation] = []
            let cutoff = Date().addingTimeInterval(-Double(Self.lookbackDays) * 86400)
            for account in accounts {
                let root = URL(fileURLWithPath: account.projectsDir)
                guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
                for case let url as URL in en where url.pathExtension == "jsonl" && !url.path.contains("/subagents/") {
                    let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    guard let mtime = vals?.contentModificationDate, mtime >= cutoff else { continue }
                    let stamp = "\(account.id)-\(vals?.fileSize ?? 0)-\(mtime.timeIntervalSince1970)"
                    let conv: Conversation?
                    if let c = newCache[url.path], c.stamp == stamp { conv = c.conv }
                    else { conv = Self.read(url, accountID: account.id); newCache[url.path] = (stamp, conv) }
                    if let conv { result.append(conv) }
                }
            }
            result.sort { $0.lastDate > $1.lastDate }
            DispatchQueue.main.async {
                self.cache = newCache
                self.conversations = result
                self.isIndexing = false
                self.lastIndexed = Date()
            }
        }
    }

    /// Conversations whose text contains every word of the query.
    func search(_ query: String) -> [Conversation] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return conversations.filter { c in words.allSatisfy { c.searchText.contains($0) || c.title.lowercased().contains($0) } }
    }

    // MARK: Reading a transcript

    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {   // thread-safe for parsing
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    nonisolated static func read(_ url: URL, accountID: String) -> Conversation? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var cwd: String?, summary: String?, firstUser: String?
        var first: Date?, last: Date?
        var count = 0
        var text = ""
        let cap = 40_000
        let markers = [Data("\"type\":\"user\"".utf8), Data("\"type\":\"assistant\"".utf8), Data("\"type\":\"summary\"".utf8)]

        for line in data.split(separator: 0x0A) where markers.contains(where: { line.range(of: $0) != nil }) {
            autoreleasepool {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let type = obj["type"] as? String else { return }
                if type == "summary" { summary = summary ?? (obj["summary"] as? String); return }
                if cwd == nil { cwd = obj["cwd"] as? String }
                if let ts = obj["timestamp"] as? String, let d = isoFrac.date(from: ts) {
                    first = first.map { min($0, d) } ?? d
                    last = last.map { max($0, d) } ?? d
                }
                guard let msg = obj["message"] as? [String: Any] else { return }
                var parts: [String] = []
                if let s = msg["content"] as? String { parts = [s] }
                else if let blocks = msg["content"] as? [[String: Any]] {
                    parts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                }
                // Drop blocks added by tools and editors (system notes, selections, command wrappers): they start with "<".
                parts = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("<") }
                let joined = parts.joined(separator: " ")
                guard !joined.isEmpty else { return }
                if type == "user" {
                    guard obj["isMeta"] as? Bool != true else { return }
                    count += 1
                    if firstUser == nil { firstUser = joined }
                }
                if text.count < cap { text += " " + joined.lowercased().prefix(cap - text.count) }
            }
        }
        guard let first, let last, count > 0 else { return nil }
        let rawTitle = (summary ?? firstUser ?? "Conversation").replacingOccurrences(of: "\n", with: " ")
        let title = rawTitle.count > 90 ? String(rawTitle.prefix(89)) + "…" : rawTitle
        return Conversation(id: url.deletingPathExtension().lastPathComponent, accountID: accountID,
                            project: cwd ?? url.deletingLastPathComponent().lastPathComponent, title: title,
                            firstDate: first, lastDate: last, messageCount: count, file: url, searchText: text)
    }
}

/// Starts Claude Code in Terminal, in a folder, on an account.
enum TerminalLauncher {
    static func launch(in folder: String, account: Account, arguments: [String], name: String) {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let claude = Integration.findClaude() ?? "claude"
        var lines = ["#!/bin/zsh", "cd \(q(folder)) || exit 1"]
        lines.append(account.isDefaultDir ? "unset CLAUDE_CONFIG_DIR" : "export CLAUDE_CONFIG_DIR=\(q(account.expandedConfigDir))")
        if let browser = Integration.browserScript(for: account) { lines.append("export BROWSER=\(q(browser))") }
        lines.append("export CLAUDE_COMPANION_BYPASS=1")
        lines.append(([q(claude)] + arguments.map(q)).joined(separator: " "))
        let path = Paths.companionDir + "/\(name).command"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
