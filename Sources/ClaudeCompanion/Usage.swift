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
        var block: UsageBlock?
        let cal = Calendar.current
        for e in entries {
            if block == nil || e.date >= block!.end {
                let start = cal.dateInterval(of: .hour, for: e.date)?.start ?? e.date
                block = UsageBlock(start: start, end: start.addingTimeInterval(5 * 3600), cost: 0, tokens: 0, output: 0)
            }
            block!.cost += e.cost
            block!.tokens += e.totalTokens
            block!.output += e.output
        }
        return block?.isActive == true ? block : nil
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

/// Reads Claude Code's JSONL transcripts under `<configDir>/projects`. Results are cached
/// per file (keyed by size + mtime) so refreshes only re-parse what changed.
final class UsageScanner {
    private var cache: [String: (stamp: String, entries: [UsageEntry])] = [:]
    private let queue = DispatchQueue(label: "usage-scanner", qos: .utility)
    static let lookbackDays = 35

    func scan(_ accounts: [Account], completion: @escaping ([String: AccountUsage]) -> Void) {
        queue.async {
            var result: [String: AccountUsage] = [:]
            for a in accounts { result[a.id] = self.scanAccount(a) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func scanAccount(_ account: Account) -> AccountUsage {
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
            let stamp = "\(vals?.fileSize ?? 0)-\(mtime.timeIntervalSince1970)"
            let entries: [UsageEntry]
            if let c = cache[url.path], c.stamp == stamp {
                entries = c.entries
            } else {
                entries = Self.parse(url)
                cache[url.path] = (stamp, entries)
            }
            for e in entries where e.date >= cutoff && seen.insert(e.key).inserted { all.append(e) }
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

    static func parse(_ url: URL) -> [UsageEntry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var out: [UsageEntry] = []
        for line in data.split(separator: 0x0A) where line.range(of: needle) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let date = isoFrac.date(from: ts) ?? iso.date(from: ts) else { continue }
            let model = msg["model"] as? String ?? "unknown"
            if model == "<synthetic>" { continue }

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
            out.append(UsageEntry(key: id + ":" + req, date: date, model: model,
                                  project: (cwd as NSString).lastPathComponent,
                                  input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead,
                                  cost: cost))
        }
        return out
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
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}
