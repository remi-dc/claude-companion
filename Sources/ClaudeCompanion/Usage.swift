import Foundation

// MARK: Pricing (USD per million tokens, Anthropic API list prices)

struct Price {
    let input: Double, output: Double, cacheRead: Double
    var cacheWrite5m: Double { input * 1.25 }
    var cacheWrite1h: Double { input * 2 }
}

enum Pricing {
    /// Ordered most-specific first.
    private static let table: [(String, Price)] = [
        ("fable-5-2", Price(input: 8, output: 40, cacheRead: 0.20)),
        ("mythos-5-2", Price(input: 8, output: 40, cacheRead: 0.20)),
        ("fable-5", Price(input: 10, output: 50, cacheRead: 1.0)),
        ("mythos", Price(input: 10, output: 50, cacheRead: 1.0)),
        ("opus-5-5", Price(input: 4, output: 20, cacheRead: 0.20)),
        ("opus-5", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("opus-4-8", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("opus-4-7", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("opus-4-6", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("opus-4-5", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("opus-4", Price(input: 15, output: 75, cacheRead: 1.50)),
        ("sonnet-5-5", Price(input: 2, output: 10, cacheRead: 0.10)),
        ("sonnet-5", Price(input: 2, output: 10, cacheRead: 0.20)),
        ("sonnet-4", Price(input: 3, output: 15, cacheRead: 0.30)),
        ("sonnet-3", Price(input: 3, output: 15, cacheRead: 0.30)),
        ("haiku-5-5", Price(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("haiku-4-5", Price(input: 1, output: 5, cacheRead: 0.10)),
        ("haiku-3-5", Price(input: 0.80, output: 4, cacheRead: 0.08)),
    ]

    static func price(for model: String) -> Price? {
        table.first { model.contains($0.0) }?.1
    }

    /// "claude-opus-5-5" -> "Opus 5.5"
    static func displayName(_ model: String) -> String {
        var m = model.replacingOccurrences(of: "claude-", with: "")
        if let r = m.range(of: #"-\d{8}$"#, options: .regularExpression) { m.removeSubrange(r) }
        let parts = m.split(separator: "-")
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }
}

// MARK: Records

struct UsageEntry {
    let key: String          // message id + request id, for de-duplication
    let session: String      // Claude Code session id
    let date: Date
    let model: String
    let project: String
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int
    let cost: Double

    var totalTokens: Int { input + output + cacheWrite + cacheRead }
}

struct UsageBlock {
    let start: Date
    let end: Date
    var cost: Double
    var tokens: Int
    var output: Int
    var isActive: Bool { Date() < end }
}

struct AccountUsage {
    let entries: [UsageEntry]   // sorted by date

    static let empty = AccountUsage(entries: [])

    func since(_ d: Date) -> ArraySlice<UsageEntry> {
        let i = entries.firstIndex { $0.date >= d } ?? entries.endIndex
        return entries[i...]
    }
    func cost(since d: Date) -> Double { since(d).reduce(0) { $0 + $1.cost } }
    func tokens(since d: Date) -> Int { since(d).reduce(0) { $0 + $1.totalTokens } }
    func output(since d: Date) -> Int { since(d).reduce(0) { $0 + $1.output } }

    /// Claude Code's rolling 5-hour windows: a window opens (hour-floored) at the first
    /// message after the previous window closed.
    var currentBlock: UsageBlock? {
        guard let block = lastBlock, block.isActive else { return nil }
        return block
    }

    /// The most recent 5-hour window, active or not.
    var lastBlock: UsageBlock? { lastBlock(now: Date()) }

    /// The most recent 5-hour window as of `now` (entries after `now` are ignored).
    func lastBlock(now: Date) -> UsageBlock? {
        var block: UsageBlock?
        let cal = Calendar.current
        for e in entries where e.date <= now {
            if block == nil || e.date >= block!.end {
                let start = cal.dateInterval(of: .hour, for: e.date)?.start ?? e.date
                block = UsageBlock(start: start, end: start.addingTimeInterval(5 * 3600), cost: 0, tokens: 0, output: 0)
            }
            block!.cost += e.cost
            block!.tokens += e.totalTokens
            block!.output += e.output
        }
        return block
    }

    /// Cost per Claude session id.
    func costBySession(since d: Date = .distantPast) -> [String: Double] {
        var acc: [String: Double] = [:]
        for e in since(d) where !e.session.isEmpty { acc[e.session, default: 0] += e.cost }
        return acc
    }

    func grouped(since d: Date, by key: (UsageEntry) -> String) -> [(name: String, cost: Double, tokens: Int)] {
        var acc: [String: (Double, Int)] = [:]
        for e in since(d) {
            let k = key(e)
            acc[k, default: (0, 0)].0 += e.cost
            acc[k, default: (0, 0)].1 += e.totalTokens
        }
        return acc.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.cost > $1.cost }
    }
}

// MARK: Scanner

/// Reads Claude Code's JSONL transcripts under `<configDir>/projects`.
/// Transcripts are append-only, so each file is read once and then only its new lines
/// on later scans. Lines are parsed one at a time inside an autorelease pool to keep memory flat.
final class UsageScanner {
    private struct FileState {
        var size: Int
        var mtime: Date
        var offset: UInt64          // bytes consumed so far (always just after a newline)
        var entries: [UsageEntry]
    }
    private var cache: [String: FileState] = [:]
    private let queue = DispatchQueue(label: "usage-scanner", qos: .utility)
    static let lookbackDays = 35

    func scan(_ accounts: [Account], completion: @escaping ([String: AccountUsage]) -> Void) {
        queue.async {
            var result: [String: AccountUsage] = [:]
            var seenPaths = Set<String>()
            for a in accounts { result[a.id] = self.scanAccount(a, seen: &seenPaths) }
            // Forget files that were deleted or aged out.
            self.cache = self.cache.filter { seenPaths.contains($0.key) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func scanAccount(_ account: Account, seen seenPaths: inout Set<String>) -> AccountUsage {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: account.projectsDir)
        let cutoff = Date().addingTimeInterval(-Double(Self.lookbackDays) * 86400)
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return .empty
        }
        var seen = Set<String>()
        var all: [UsageEntry] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let mtime = vals?.contentModificationDate, mtime >= cutoff else { continue }
            let size = vals?.fileSize ?? 0
            let path = url.path
            seenPaths.insert(path)

            var state: FileState
            if let cached = cache[path], cached.size == size, cached.mtime == mtime {
                state = cached                                       // unchanged
            } else if let cached = cache[path], size > cached.size {
                state = cached                                       // grew: read only the new lines
                let (more, offset) = Self.parse(url, from: cached.offset)
                state.entries += more
                state.offset = offset
                state.size = size
                state.mtime = mtime
            } else {
                let (entries, offset) = Self.parse(url, from: 0)    // new or rewritten: read it all
                state = FileState(size: size, mtime: mtime, offset: offset, entries: entries)
            }
            cache[path] = state
            for e in state.entries where e.date >= cutoff && seen.insert(e.key).inserted { all.append(e) }
        }
        all.sort { $0.date < $1.date }
        return AccountUsage(entries: all)
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let needle = Data("\"usage\"".utf8)

    /// Parses complete lines from `offset` to the last newline. Returns the entries and the new offset.
    static func parse(_ url: URL, from offset: UInt64) -> ([UsageEntry], UInt64) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: offset)) != nil, let data = try? fh.readToEnd(), !data.isEmpty,
              let lastNewline = data.lastIndex(of: 0x0A) else { return ([], offset) }

        var out: [UsageEntry] = []
        let complete = data[data.startIndex...lastNewline]
        for line in complete.split(separator: 0x0A) where line.range(of: needle) != nil {
            autoreleasepool {
                if let entry = parseLine(line, url: url) { out.append(entry) }
            }
        }
        return (out, offset + UInt64(lastNewline - data.startIndex + 1))
    }

    private static func parseLine(_ line: Data.SubSequence, url: URL) -> UsageEntry? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let date = isoFrac.date(from: ts) ?? iso.date(from: ts) else { return nil }
        let model = msg["model"] as? String ?? "unknown"
        if model == "<synthetic>" { return nil }

        func int(_ d: [String: Any]?, _ k: String) -> Int { (d?[k] as? NSNumber)?.intValue ?? 0 }
        let input = int(usage, "input_tokens")
        let output = int(usage, "output_tokens")
        let cacheRead = int(usage, "cache_read_input_tokens")
        let cacheWrite = int(usage, "cache_creation_input_tokens")
        let cc = usage["cache_creation"] as? [String: Any]
        let w1h = int(cc, "ephemeral_1h_input_tokens")
        let w5m = cc == nil ? cacheWrite : int(cc, "ephemeral_5m_input_tokens")

        var cost = 0.0
        if let p = Pricing.price(for: model) {
            cost = (Double(input) * p.input + Double(output) * p.output + Double(cacheRead) * p.cacheRead
                    + Double(w5m) * p.cacheWrite5m + Double(w1h) * p.cacheWrite1h) / 1_000_000
            if usage["speed"] as? String == "fast" { cost *= 2 }
        }

        let id = msg["id"] as? String ?? UUID().uuidString
        let req = obj["requestId"] as? String ?? ""
        let cwd = obj["cwd"] as? String ?? url.deletingLastPathComponent().lastPathComponent
        return UsageEntry(key: id + ":" + req, session: obj["sessionId"] as? String ?? "", date: date, model: model,
                          project: (cwd as NSString).lastPathComponent,
                          input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead,
                          cost: cost)
    }
}

// MARK: Formatting

enum Fmt {
    static func usd(_ v: Double) -> String {
        v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1e3)
        default: return "\(n)"
        }
    }
    static func remaining(until d: Date) -> String {
        let s = max(0, Int(d.timeIntervalSinceNow))
        if s < 3600 { return "\((s % 3600) / 60)m" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}
