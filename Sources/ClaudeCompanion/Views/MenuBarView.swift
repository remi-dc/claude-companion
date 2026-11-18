import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Namespace private var accountSelection
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var account: Account { state.activeAccount }
    private var usage: AccountUsage { state.usage[account.id] ?? .empty }
    private var accountColor: Color { state.config.color(for: account.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            accountSwitcher
            windowCard
            HStack(spacing: 10) {
                todayCard
                trendCard
            }
            activity
            footer
        }
        .padding(16)
        .frame(width: 348)
        .tint(Ember.accent)
        .onAppear {
            appeared = false
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.9).delay(0.05)) { appeared = true }
        }
        .onDisappear { appeared = false }
    }

    // MARK: Header — Flick and his line

    private var header: some View {
        let line = state.statusLine
        return HStack(spacing: 12) {
            FlickView(mood: state.mood, size: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(.system(size: 15, weight: .semibold))
                    .contentTransition(.opacity)
                Text(line.subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .animation(.easeInOut(duration: 0.25), value: line.title)
            Spacer(minLength: 4)
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { state.config.paused.toggle() }
            } label: {
                Image(systemName: state.config.paused ? "bell.slash.fill" : "bell.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(state.config.paused ? Color.secondary : Ember.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Ember.card))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(state.config.paused ? "Resume notifications" : "Pause notifications")
            .accessibilityLabel(state.config.paused ? "Resume notifications" : "Pause notifications")
        }
    }

    // MARK: Accounts

    private var accountSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(state.config.accounts) { a in
                let active = a.id == state.config.activeAccountID
                let color = state.config.color(for: a.id)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) { state.activate(a.id) }
                } label: {
                    VStack(spacing: 5) {
                        ZStack(alignment: .topTrailing) {
                            Circle().fill(color)
                                .frame(width: 34, height: 34)
                                .overlay(Image(systemName: a.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
                                .overlay(Circle().stroke(color, lineWidth: 2).padding(-4).opacity(active ? 1 : 0))
                            if state.needsYou(a.id) {
                                Circle().fill(Ember.accent)
                                    .frame(width: 11, height: 11)
                                    .overlay(Circle().stroke(Ember.card, lineWidth: 2))
                                    .offset(x: 3, y: -3)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        Text(a.name)
                            .font(.caption)
                            .fontWeight(active ? .semibold : .regular)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if active {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Ember.cardRaised)
                                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "selection", in: accountSelection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(a.loggedInEmail ?? "Not logged in")
                .accessibilityLabel("\(a.name)\(active ? ", active" : "")")
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ember.card))
    }

    // MARK: Usage

    private var windowCard: some View {
        let block = usage.currentBlock
        let fraction = block.map { min(1, max(0, Date().timeIntervalSince($0.start) / (5 * 3600))) } ?? 0
        return EmberCard(padding: 14) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Ember.ringTrack, lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: appeared ? fraction : 0)
                        .stroke(Ember.ring, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(block.map { Fmt.remaining(until: $0.end) } ?? "—")
                            .font(.number(14))
                        Text(block == nil ? "no window" : "left")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 84)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(block.map { "5-hour window, \(Fmt.remaining(until: $0.end)) left" } ?? "No active 5-hour window")

                VStack(alignment: .leading, spacing: 2) {
                    Text("5-hour window · \(account.name)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.usd(appeared ? (block?.cost ?? 0) : 0))
                        .font(.number(32))
                        .contentTransition(.numericText())
                    Text(block.map { "\(Fmt.tokens($0.tokens)) tokens · resets \($0.end.formatted(date: .omitted, time: .shortened))" }
                         ?? "Starts with your next prompt")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var todayCard: some View {
        let today = Calendar.current.startOfDay(for: Date())
        return EmberCard {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(.caption).foregroundStyle(.secondary)
                Text(Fmt.usd(appeared ? usage.cost(since: today) : 0))
                    .font(.number(22))
                    .contentTransition(.numericText())
                Text("\(Fmt.tokens(usage.tokens(since: today))) tokens")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var trendCard: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days: [Double] = (0..<7).map { i in
            let start = cal.date(byAdding: .day, value: i - 6, to: today)!
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            return usage.since(start).filter { $0.date < end }.reduce(0) { $0 + $1.cost }
        }
        return EmberCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last 7 days").font(.caption).foregroundStyle(.secondary)
                Sparkline(values: days, progress: appeared ? 1 : 0)
                    .frame(height: 34)
                    .accessibilityLabel("Daily cost over the last 7 days, \(Fmt.usd(days.reduce(0, +))) in total")
            }
        }
    }

    // MARK: Activity

    private var activity: some View {
        let live = state.liveSessions
        let needs = live.filter { $0.mood == .needs }
        let working = live.filter { $0.mood == .working }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Activity").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 2)

            ForEach(needs) { s in
                HStack(spacing: 10) {
                    Circle().fill(Ember.accent).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Needs permission · \(s.project)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(accountName(s.accountID)) · \(s.date.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if s.appBundleID != nil {
                        Button("Open") { state.open(s) }
                            .buttonStyle(EmberButtonStyle())
                            .help("Bring this session's app to the front")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ember.alert))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ForEach(working) { s in
                row(dot: state.config.color(for: s.accountID), title: "Working · \(s.project)",
                    detail: "\(accountName(s.accountID)) · started \(s.date.formatted(.relative(presentation: .named)))",
                    open: s.appBundleID == nil ? nil : { state.open(s) })
            }

            // History: skip sessions already shown above, and show each session once.
            let shown = Set(live.filter { $0.mood != .done }.map(\.id))
            let history = state.recent.reduce(into: [HookMessage]()) { acc, m in
                let key = m.sessionID ?? "\(m.accountID)/\(m.project)"
                if !shown.contains(key), !acc.contains(where: { ($0.sessionID ?? "\($0.accountID)/\($0.project)") == key }) {
                    acc.append(m)
                }
            }
            ForEach(history.prefix(max(0, 3 - working.count - needs.count))) { msg in
                row(dot: state.config.color(for: msg.accountID), title: "\(msg.event.title) · \(msg.project)",
                    detail: "\(accountName(msg.accountID)) · \(msg.date.formatted(.relative(presentation: .named)))",
                    open: nil)
            }

            if needs.isEmpty && working.isEmpty && state.recent.isEmpty {
                Text(state.config.friendlyMessages ? "Nothing yet. I'll let you know when Claude needs you." : "No activity yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: live)
    }

    private func row(dot: Color, title: String, detail: String, open: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Circle().fill(dot).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let open {
                Button(action: open) { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless)
                    .help("Bring this session's app to the front")
                    .accessibilityLabel("Open session")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func accountName(_ id: String) -> String { state.config.account(id)?.name ?? id }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { WindowManager.shared.show("dashboard", state: state) } label: {
                Label("Dashboard", systemImage: "chart.bar.xaxis").frame(maxWidth: .infinity)
            }
            .buttonStyle(EmberPillStyle())
            Button { WindowManager.shared.show("settings", state: state) } label: {
                Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
            }
            .buttonStyle(EmberPillStyle())
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").frame(width: 30, height: 30)
            }
            .buttonStyle(EmberPillStyle(compact: true))
            .help("Quit Claude Companion")
            .accessibilityLabel("Quit")
        }
        .padding(.top, 4)
    }
}

// MARK: Pieces

struct Sparkline: View {
    var values: [Double]
    var progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 0, 0.01)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: geo.size.height - 3 - (geo.size.height - 6) * CGFloat(v / maxV))
            }
            ZStack(alignment: .topLeading) {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .trim(from: 0, to: progress)
                .stroke(Ember.ring, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(Ember.ring).frame(width: 6, height: 6)
                        .position(last)
                        .opacity(progress >= 1 ? 1 : 0)
                }
            }
        }
    }
}

struct EmberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ember.accent))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct EmberPillStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, compact ? 0 : 10)
            .padding(.vertical, compact ? 0 : 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Ember.card))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
