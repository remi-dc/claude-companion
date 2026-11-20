import AppKit
import SwiftUI

/// `ClaudeCompanion demo-shots <dir> [light|dark]` — runs the app on made-up data (no real accounts,
/// no hooks, no files touched), opens its windows and writes their window numbers to <dir>/windows.txt
/// so they can be captured for the README. Also renders the Flick strip and the icon.
enum Demo {
    static var outDir: String?
    static var dark = false
    /// When set, only the Settings window opens, on this pane (for screenshots).
    static var settingsPane: String?
    static var isOn: Bool { outDir != nil }

    static func config() -> CompanionConfig {
        var c = CompanionConfig.defaults
        c.accounts = c.accounts.map { var a = $0; a.configDir = "/tmp/claude-companion-demo/\($0.id)"; return a }
        c.activeAccountID = "personal"
        return c
    }

    /// 30 days of plausible usage, deterministic so the shots don't change between runs.
    static func usage(now: Date = Date()) -> [String: AccountUsage] {
        var seed: UInt64 = 42
        func rand() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        let cal = Calendar.current
        let plan: [(id: String, projects: [String], daily: Double)] = [
            ("personal", ["landing-page", "notes-app", "recipe-bot"], 9),
            ("work", ["billing-api", "data-pipeline", "admin-portal"], 14),
            ("backup", ["docs-site"], 2.5),
        ]
        var result: [String: AccountUsage] = [:]
        for p in plan {
            var entries: [UsageEntry] = []
            for day in (1...29).reversed() {
                guard let date = cal.date(byAdding: .day, value: -day, to: now), rand() > 0.22 else { continue }
                let weekend = cal.isDateInWeekend(date)
                let total = p.daily * (weekend ? 0.3 : 0.6 + rand() * 1.1)
                let n = 3 + Int(rand() * 5)
                for i in 0..<n {
                    let at = cal.date(bySettingHour: 9 + Int(rand() * 10), minute: Int(rand() * 59), second: i, of: date)!
                    entries.append(entry(p.projects[Int(rand() * Double(p.projects.count))], at, total / Double(n), "\(p.id)-\(day)-\(i % 2)", rand()))
                }
            }
            // Today: an active 5-hour window.
            let todayCount = p.id == "backup" ? 0 : 6
            for i in 0..<todayCount {
                let at = now.addingTimeInterval(-Double(100 - i * 15) * 60)
                entries.append(entry(p.projects[i % 2], at, p.id == "personal" ? 2.1 : 1.4, "\(p.id)-today", rand()))
            }
            result[p.id] = AccountUsage(entries: entries.sorted { $0.date < $1.date })
        }
        return result
    }

    private static func entry(_ project: String, _ date: Date, _ cost: Double, _ session: String, _ r: Double) -> UsageEntry {
        let model = r < 0.75 ? "claude-opus-5-5" : (r < 0.95 ? "claude-sonnet-5-5" : "claude-haiku-5-5")
        return UsageEntry(key: UUID().uuidString, session: session, date: date, model: model, project: project,
                          input: Int(cost * 2_000), output: Int(cost * 9_000), cacheWrite: Int(cost * 40_000),
                          cacheRead: Int(cost * 220_000), cost: cost)
    }

    static func sessions(now: Date = Date()) -> [String: SessionStatus] {
        func s(_ id: String, _ account: String, _ project: String, _ mood: FlickMood, ago: Double, ran: Double, app: String) -> SessionStatus {
            let date = now.addingTimeInterval(-ago)
            return SessionStatus(id: id, accountID: account, project: project, mood: mood, date: date,
                                 startedAt: date.addingTimeInterval(-ran), appBundleID: app,
                                 location: SessionLocation(appBundleID: app, cwd: "/demo/\(project)", tty: nil, sessionID: id))
        }
        let list = [
            s("work-today", "work", "billing-api", .needs, ago: 40, ran: 260, app: "com.microsoft.VSCode"),
            s("personal-today", "personal", "landing-page", .working, ago: 5, ran: 420, app: "com.apple.Terminal"),
            s("personal-3", "personal", "notes-app", .done, ago: 180, ran: 95, app: "com.apple.Terminal"),
            s("backup-1", "backup", "docs-site", .done, ago: 3_900, ran: 600, app: "com.microsoft.VSCode"),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    static func recent(now: Date = Date()) -> [HookMessage] {
        [HookMessage(date: now.addingTimeInterval(-180), accountID: "personal", event: .finished, project: "notes-app",
                     body: "Added offline sync and updated the tests.", sessionID: "personal-3"),
         HookMessage(date: now.addingTimeInterval(-3_900), accountID: "backup", event: .finished, project: "docs-site",
                     body: "Fixed the broken links.", sessionID: "backup-1")]
    }

    /// `demo-shots <dir> light notch:<phase>`: the notch in one state, on made-up content.
    @MainActor
    static func runNotch(_ state: AppState, phase: String) {
        let notch = NotchController.shared
        state.config.notch.presentation = "both"
        if !phase.hasPrefix("working") {
            for k in state.sessions.keys where state.sessions[k]?.mood == .working { state.sessions[k]?.mood = .done }
        }
        if phase != "needs" && !phase.hasPrefix("expanded") {
            for k in state.sessions.keys where state.sessions[k]?.mood == .needs { state.sessions[k]?.mood = .done }
        }
        if phase.hasPrefix("working") { state.sessions["personal-today"]?.activity = "Editing HeroSection.swift" }
        notch.apply(state)
        notch.music.demoTrack = .init(app: "Spotify", title: "[Track title]", artist: "[Artist]", artworkURL: nil, isPlaying: true, position: 72, duration: 214)
        notch.calendar.demo = true
        notch.calendar.access = .fullAccess
        let now = Date()
        notch.calendar.events = [
            .init(id: "1", title: "Design review", start: now.addingTimeInterval(12 * 60), end: now.addingTimeInterval(42 * 60),
                  joinURL: URL(string: "https://meet.google.com/demo")),
            .init(id: "2", title: "1:1 with Sam", start: now.addingTimeInterval(3 * 3600), end: now.addingTimeInterval(3.5 * 3600), joinURL: nil),
        ]
        notch.shelf.items = ["report.pdf", "screenshot.png", "notes.md"].map { URL(fileURLWithPath: "/System/Library/CoreServices/\($0)") }
        notch.clipboard.clips = ["git checkout -b fix/login", "https://github.com/acme/app/pull/42", "#D9653B", "Ship it after the review"]
            .enumerated().map { .init(text: $1, date: now.addingTimeInterval(-Double($0 * 400 + 60))) }
        if phase == "expanded-calendar-free" {
            notch.calendar.events = [
                .init(id: "3", title: "Team standup", start: Calendar.current.startOfDay(for: now).addingTimeInterval(33 * 3600),
                      end: Calendar.current.startOfDay(for: now).addingTimeInterval(33.25 * 3600), joinURL: URL(string: "https://meet.google.com/demo")),
                .init(id: "4", title: "Sprint planning", start: Calendar.current.startOfDay(for: now).addingTimeInterval(58 * 3600),
                      end: Calendar.current.startOfDay(for: now).addingTimeInterval(59 * 3600), joinURL: nil),
            ]
        }
        switch phase {
        case "needs", "needs-folded":
            notch.model.show(NotchAlert(id: "work-today", title: "Work needs a hand", subtitle: "Work · billing-api",
                                        body: "Claude needs your permission to use Bash", mood: .needs,
                                        location: state.sessions["work-today"]?.location, stays: true))
        case "done":
            notch.model.show(NotchAlert(id: "done", title: "notes-app is ready", subtitle: "Personal · notes-app",
                                        body: "Added offline sync, updated the tests and the README.", mood: .done,
                                        location: state.sessions["personal-3"]?.location, copyText: "…", stays: true))
        default:
            if phase.hasPrefix("expanded") {
                notch.model.tab = NotchTab(rawValue: String(phase.dropFirst("expanded-".count).prefix { $0 != "-" })) ?? .claude
                notch.model.expanded = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let dir = outDir, let n = notch.windowNumber else { return }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? "Notch\t\(n)".write(toFile: dir + "/windows.txt", atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    static func run(_ state: AppState) {
        if let pane = settingsPane, pane.hasPrefix("notch:") {
            runNotch(state, phase: String(pane.dropFirst("notch:".count)))
            return
        }
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for id in settingsPane == nil ? ["popover", "sessions", "dashboard"] : ["settings"] {
                WindowManager.shared.show(id, state: state)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let dir = outDir else { return }
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let lines = NSApp.windows.filter { $0.isVisible && !$0.title.isEmpty }.map { "\($0.title)\t\($0.windowNumber)" }
                try? lines.joined(separator: "\n").write(toFile: dir + "/windows.txt", atomically: true, encoding: .utf8)
                renderStatic(to: dir)
            }
        }
    }

    @MainActor
    private static func renderStatic(to dir: String) {
        func save<V: View>(_ view: V, _ name: String, scale: CGFloat = 2) {
            let r = ImageRenderer(content: view)
            r.scale = scale
            if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
            }
        }
        let moods: [(FlickMood, String)] = [(.idle, "Idle"), (.working, "Working"), (.needs, "Needs you"), (.done, "Done"), (.sleep, "Sleeping")]
        save(HStack(spacing: 28) {
            ForEach(moods, id: \.1) { mood, label in
                VStack(spacing: 6) {
                    FlickView(mood: mood, size: 96, animated: false)
                    Text(label).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Color(hex: 0x8E8E93))
                }
            }
        }.padding(16), "flick.png")
        save(AppIconView(), "icon.png", scale: 0.25)
    }
}
