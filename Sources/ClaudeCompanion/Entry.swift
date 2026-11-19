import Foundation

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == "hook" {
            HookCLI.run(Array(args.dropFirst(2)))
            exit(0)
        }
        // `ClaudeCompanion open [dashboard|settings]` — asks the running app to show a window.
        if args.count > 1 && args[1] == "open" {
            DistributedNotificationCenter.default().postNotificationName(
                kOpenWindowNotification, object: nil,
                userInfo: ["window": args.count > 2 ? args[2] : "dashboard"], deliverImmediately: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            exit(0)
        }
        if args.count > 2 && args[1] == "render-icon" {
            MainActor.assumeIsolated { AppIconView.renderIconset(to: args[2]) }
            exit(0)
        }
        // `ClaudeCompanion check-update` — compares this build with the latest GitHub release.
        if args.count > 1 && args[1] == "check-update" {
            let done = DispatchSemaphore(value: 0)
            let feed = URL(string: ProcessInfo.processInfo.environment["CLAUDE_COMPANION_UPDATE_URL"]
                           ?? "https://api.github.com/repos/\(Updater.repo)/releases/latest")!
            Task.detached {
                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                do {
                    if let r = try await Updater.fetchLatest(from: feed) {
                        print("installed \(current), latest \(r.version): \(Updater.isNewer(r.version, than: current) ? "update available" : "up to date")")
                        print("download: \(r.zipURL.absoluteString)")
                    } else { print("installed \(current), no release found") }
                } catch { print("check failed: \(error.localizedDescription)") }
                done.signal()
            }
            done.wait()
            exit(0)
        }
        if args.count > 2 && args[1] == "demo-shots" {
            Demo.outDir = args[2]
            Demo.dark = args.count > 3 && args[3] == "dark"
            CompanionApp.main()
        }
        if args.count > 1 && args[1] == "usage" {
            printUsage()
            exit(0)
        }
        CompanionApp.main()
    }
}

/// `ClaudeCompanion usage` — prints a usage summary per account to the terminal.
private func printUsage() {
    let cfg = CompanionConfig.load()
    let done = DispatchSemaphore(value: 0)
    var result: [String: AccountUsage] = [:]
    let scanner = UsageScanner()
    DispatchQueue.global().async {
        scanner.scan(cfg.accounts) { result = $0; done.signal() }
    }
    // scan() completes on the main queue, so pump it.
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    let today = Calendar.current.startOfDay(for: Date())
    let month = today.addingTimeInterval(-29 * 86400)
    for a in cfg.accounts {
        let u = result[a.id] ?? .empty
        print("\(a.name) (\(a.expandedConfigDir))\(a.id == cfg.activeAccountID ? "  [active]" : "")")
        if let b = u.currentBlock {
            print("  5h window : \(Fmt.usd(b.cost))  \(Fmt.tokens(b.tokens)) tokens, resets in \(Fmt.remaining(until: b.end))")
        }
        print("  today     : \(Fmt.usd(u.cost(since: today)))  \(Fmt.tokens(u.tokens(since: today))) tokens")
        print("  30 days   : \(Fmt.usd(u.cost(since: month)))  \(Fmt.tokens(u.tokens(since: month))) tokens")
        for m in u.grouped(since: month, by: { Pricing.displayName($0.model) }).prefix(5) {
            print("    \(m.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(Fmt.usd(m.cost))")
        }
    }
}
