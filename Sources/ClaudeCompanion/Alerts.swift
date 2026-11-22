import Foundation

/// Usage alerts. Evaluated after each usage scan (every minute); each alert fires once per
/// period (month, 5-hour window, day) and nothing fires while notifications are paused.
@MainActor
enum AlertsEngine {
    private static let firedKey = "firedAlerts"

    struct Alert: Equatable {
        let key: String, title: String, body: String, mood: FlickMood, accountID: String?
    }

    static func evaluate(_ state: AppState, now: Date = Date()) {
        guard !state.config.paused else { return }
        var fired = Set(UserDefaults.standard.stringArray(forKey: firedKey) ?? [])
        let before = fired
        for alert in compute(config: state.config, usage: state.usage, now: now, fired: &fired) {
            state.presentAlert(id: alert.key, title: alert.title, body: alert.body, mood: alert.mood,
                               account: alert.accountID.flatMap { state.config.account($0) })
        }
        if fired != before {
            // Must be a real Array: an ArraySlice isn't a property list and made UserDefaults throw (crash).
            UserDefaults.standard.set(Array(Array(fired).sorted().suffix(300)), forKey: firedKey)
        }
    }

    /// Pure: which alerts are due, given settings, usage and what already fired (updated in place).
    nonisolated static func compute(config: CompanionConfig, usage allUsage: [String: AccountUsage], now: Date,
                        fired: inout Set<String>) -> [Alert] {
        let settings = config.alerts
        let cal = Calendar.current
        var out: [Alert] = []
        func fire(_ key: String, _ title: String, _ body: String, _ mood: FlickMood, account: Account? = nil) {
            guard fired.insert(key).inserted else { return }
            out.append(Alert(key: key, title: title, body: body, mood: mood, accountID: account?.id))
        }
        func usd(_ v: Double) -> String { Fmt.usd(v) }
        func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
        let friendly = config.friendlyMessages

        for account in config.accounts {
            let usage = allUsage[account.id] ?? .empty

            // Monthly budget: 80% then 100%.
            if settings.budgetEnabled, let budget = settings.budgets[account.id], budget > 0,
               let month = cal.dateInterval(of: .month, for: now) {
                let spent = usage.cost(since: month.start)
                let monthKey = "\(cal.component(.year, from: now))-\(cal.component(.month, from: now))"
                if spent >= budget {
                    fire("budget-\(account.id)-\(monthKey)-100",
                         friendly ? "\(account.name) went over budget" : "\(account.name): monthly budget reached",
                         "\(usd(spent)) this month, budget \(usd(budget)).", .needs, account: account)
                } else if spent >= budget * 0.8 {
                    fire("budget-\(account.id)-\(monthKey)-80",
                         friendly ? "\(account.name) is at 80% of its budget" : "\(account.name): 80% of monthly budget",
                         "\(usd(spent)) of \(usd(budget)) this month.", .idle, account: account)
                }
            }

            guard let block = usage.lastBlock(now: now) else { continue }
            let blockKey = Int(block.start.timeIntervalSince1970)
            let active = now < block.end

            // Busy 5-hour window.
            if settings.windowEnabled, active, block.cost >= settings.windowThreshold {
                fire("window-\(account.id)-\(blockKey)",
                     friendly ? "\(account.name) is having a busy window" : "\(account.name): 5-hour window above \(usd(settings.windowThreshold))",
                     "\(usd(block.cost)) used so far. It resets at \(time(block.end)).", .working, account: account)
            }

            // A busy window just reset (only within 2 hours of the reset, so old windows stay quiet).
            if settings.resetEnabled, !active, now.timeIntervalSince(block.end) < 2 * 3600,
               block.cost >= max(5, settings.windowThreshold / 2) {
                fire("reset-\(account.id)-\(blockKey)",
                     friendly ? "Fresh start on \(account.name)" : "\(account.name): 5-hour window reset",
                     "Your window reset at \(time(block.end)). The last one used \(usd(block.cost)).", .done, account: account)
            }
        }

        // Daily summary.
        if settings.summaryEnabled,
           let at = cal.date(bySettingHour: settings.summaryHour, minute: 0, second: 0, of: now), now >= at {
            let dayKey = "summary-\(cal.component(.year, from: now))-\(cal.ordinality(of: .day, in: .year, for: now) ?? 0)"
            if !fired.contains(dayKey) {
                let today = cal.startOfDay(for: now)
                let entries = config.accounts.flatMap { allUsage[$0.id]?.since(today) ?? [] }.filter { $0.date <= now }
                let cost = entries.reduce(0) { $0 + $1.cost }
                if cost > 0 {
                    let sessions = Set(entries.map(\.session).filter { !$0.isEmpty }).count
                    var byProject: [String: Double] = [:]
                    entries.forEach { byProject[$0.project, default: 0] += $0.cost }
                    let top = byProject.max { $0.value < $1.value }?.key ?? "—"
                    fire(dayKey, friendly ? "Your day with Claude" : "Today's usage",
                         "\(sessions) session\(sessions == 1 ? "" : "s") · \(usd(cost)) · most active: \(top)", .done)
                } else {
                    fired.insert(dayKey)   // nothing to report today
                }
            }
        }
        return out
    }
}
