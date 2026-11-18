import Charts
import SwiftUI

/// Categorical palette (fixed order; light/dark steps chosen per surface, CVD-validated).
enum SeriesPalette {
    private static let light = [0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4, 0x008300, 0x6250d6, 0xe34948]
    private static let dark  = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x0ca30c, 0x9085e9, 0xe66767]

    static func color(_ slot: Int) -> Color {
        guard slot >= 0 else { return Color(nsColor: .systemGray) }
        let i = slot % light.count
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark[i] : light[i]
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }

    /// Model families keep the same color regardless of which ones are present.
    static let families = ["Opus", "Sonnet", "Haiku", "Fable", "Mythos"]
    static func family(_ model: String) -> String {
        families.first { model.lowercased().contains($0.lowercased()) } ?? "Other"
    }
}

private enum Scope: Hashable { case all, account(String) }

private struct DayPoint: Identifiable {
    let day: Date, series: String, cost: Double
    var id: String { "\(day.timeIntervalSince1970)-\(series)" }
}

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @State private var scope: Scope = .all
    @State private var days = 30
    @State private var selectedDay: Date?

    private var rangeStart: Date {
        Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!
    }
    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    private var scopedAccounts: [Account] {
        switch scope {
        case .all: return state.config.accounts
        case .account(let id): return state.config.accounts.filter { $0.id == id }
        }
    }

    private var combined: AccountUsage {
        AccountUsage(entries: scopedAccounts.flatMap { state.usage[$0.id]?.entries ?? [] }.sorted { $0.date < $1.date })
    }

    // Series domain + colors, fixed by entity.
    private var seriesDomain: [String] {
        if case .all = scope { return state.config.accounts.map(\.name) }
        return SeriesPalette.families + ["Other"]
    }
    private var seriesColors: [Color] {
        if case .all = scope { return state.config.accounts.indices.map(SeriesPalette.color) }
        return SeriesPalette.families.indices.map(SeriesPalette.color) + [SeriesPalette.color(-1)]
    }

    private var points: [DayPoint] {
        var acc: [Date: [String: Double]] = [:]
        let cal = Calendar.current
        for a in scopedAccounts {
            for e in state.usage[a.id]?.since(rangeStart) ?? [] {
                let series: String
                if case .all = scope { series = a.name } else { series = SeriesPalette.family(e.model) }
                acc[cal.startOfDay(for: e.date), default: [:]][series, default: 0] += e.cost
            }
        }
        return acc.flatMap { day, m in m.map { DayPoint(day: day, series: $0.key, cost: $0.value) } }
            .sorted { (seriesDomain.firstIndex(of: $0.series) ?? 99) < (seriesDomain.firstIndex(of: $1.series) ?? 99) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls
                tiles
                if case .all = scope { accountCards }
                chartCard
                HStack(alignment: .top, spacing: 16) {
                    BreakdownTable(title: "By model",
                                   rows: combined.grouped(since: rangeStart) { Pricing.displayName($0.model) })
                    BreakdownTable(title: "By project",
                                   rows: Array(combined.grouped(since: rangeStart) { $0.project }.prefix(10)))
                }
                Text("Costs are estimates at Anthropic API list prices, computed from local Claude Code transcripts (last \(UsageScanner.lookbackDays) days). Subscription plans aren't billed per token — use this to compare accounts and spot heavy sessions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onAppear { state.refreshUsage() }
    }

    private var controls: some View {
        HStack {
            Picker("", selection: $scope) {
                Text("All accounts").tag(Scope.all)
                ForEach(state.config.accounts) { Text($0.name).tag(Scope.account($0.id)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("", selection: $days) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if let t = state.lastScan {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { state.refreshUsage() } label: {
                if state.isScanning { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .help("Rescan transcripts")
        }
    }

    private var tiles: some View {
        let u = combined
        return HStack(spacing: 12) {
            if case .account = scope {
                if let b = u.currentBlock {
                    StatTile(title: "Current 5h window", value: Fmt.usd(b.cost),
                             detail: "\(Fmt.tokens(b.tokens)) tokens · resets in \(Fmt.remaining(until: b.end))")
                } else {
                    StatTile(title: "Current 5h window", value: "—", detail: "No active window")
                }
            }
            StatTile(title: "Today", value: Fmt.usd(u.cost(since: today)),
                     detail: "\(Fmt.tokens(u.tokens(since: today))) tokens")
            StatTile(title: "Last \(days) days", value: Fmt.usd(u.cost(since: rangeStart)),
                     detail: "\(Fmt.tokens(u.tokens(since: rangeStart))) tokens")
            StatTile(title: "Output tokens · \(days)d", value: Fmt.tokens(u.output(since: rangeStart)),
                     detail: "\(u.since(rangeStart).count) responses")
        }
    }

    private var accountCards: some View {
        HStack(spacing: 12) {
            ForEach(Array(state.config.accounts.enumerated()), id: \.element.id) { i, a in
                let u = state.usage[a.id] ?? .empty
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(SeriesPalette.color(i)).frame(width: 10, height: 10)
                        Text(a.name).fontWeight(.semibold)
                        if a.id == state.config.activeAccountID {
                            Text("Active").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        }
                    }
                    if let b = u.currentBlock {
                        Text("5h: \(Fmt.usd(b.cost)) · resets \(Fmt.remaining(until: b.end))").font(.caption)
                    } else {
                        Text("5h: no active window").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Today \(Fmt.usd(u.cost(since: today))) · \(days)d \(Fmt.usd(u.cost(since: rangeStart)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }
        }
    }

    private var chartCard: some View {
        let pts = points
        let selected = selectedDay.map { Calendar.current.startOfDay(for: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Daily cost").font(.headline)
            Text(scopeIsAll ? "Stacked by account" : "Stacked by model family")
                .font(.caption).foregroundStyle(.secondary)
            if pts.isEmpty {
                ContentUnavailableView("No usage yet", systemImage: "chart.bar",
                                       description: Text("Nothing in the last \(days) days for this scope."))
                    .frame(height: 240)
            } else {
                Chart {
                    ForEach(pts) { p in
                        BarMark(x: .value("Day", p.day, unit: .day), y: .value("Cost", p.cost), width: .ratio(0.7))
                            .foregroundStyle(by: .value("Series", p.series))
                            .opacity(selected == nil || selected == p.day ? 1 : 0.45)
                    }
                    if let selected {
                        RuleMark(x: .value("Day", selected, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                tooltip(for: selected, pts: pts)
                            }
                    }
                }
                .chartForegroundStyleScale(domain: seriesDomain, range: seriesColors)
                .chartXSelection(value: $selectedDay)
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.usd(d)) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: days > 7 ? 5 : 1)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 260)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
    }

    private var scopeIsAll: Bool { if case .all = scope { return true } else { return false } }

    private func tooltip(for day: Date, pts: [DayPoint]) -> some View {
        let rows = pts.filter { $0.day == day }
        return VStack(alignment: .leading, spacing: 3) {
            Text(day.formatted(.dateTime.weekday(.abbreviated).month().day())).font(.caption).fontWeight(.semibold)
            ForEach(rows) { r in
                HStack(spacing: 6) {
                    let idx = seriesDomain.firstIndex(of: r.series) ?? 0
                    RoundedRectangle(cornerRadius: 2).fill(seriesColors[idx]).frame(width: 8, height: 8)
                    Text(r.series).font(.caption)
                    Spacer(minLength: 12)
                    Text(Fmt.usd(r.cost)).font(.caption.monospacedDigit())
                }
            }
            if rows.count > 1 {
                Divider()
                HStack {
                    Text("Total").font(.caption)
                    Spacer()
                    Text(Fmt.usd(rows.reduce(0) { $0 + $1.cost })).font(.caption.monospacedDigit()).fontWeight(.semibold)
                }
            }
        }
        .padding(8)
        .frame(minWidth: 150)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial).shadow(radius: 2))
    }
}

struct StatTile: View {
    let title: String, value: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold).monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

private struct BreakdownTable: View {
    let title: String
    let rows: [(name: String, cost: Double, tokens: Int)]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if rows.isEmpty {
                Text("No data").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.name) { r in
                HStack {
                    Text(r.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Fmt.tokens(r.tokens)).foregroundStyle(.secondary).font(.callout.monospacedDigit())
                    Text(Fmt.usd(r.cost)).font(.callout.monospacedDigit()).frame(width: 70, alignment: .trailing)
                }
                .font(.callout)
                Divider().opacity(0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
    }
}
