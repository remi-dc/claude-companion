import SwiftUI

/// Applies Flick's color and calm mode from the settings to everything inside.
struct FlickThemed: ViewModifier {
    @EnvironmentObject var state: AppState
    func body(content: Content) -> some View {
        content
            .environment(\.flickPalette, state.flickPalette)
            .environment(\.flickCalm, state.config.flick.calm)
    }
}

/// Every Claude session across accounts: what's live, how long it has run, what it cost, and a way back to it.
struct SessionsView: View {
    @EnvironmentObject var state: AppState

    private var rows: [SessionStatus] {
        let liveIDs = Set(state.liveSessions.filter { $0.mood != .done }.map(\.id))
        return state.sessions.values.sorted { a, b in
            let la = liveIDs.contains(a.id), lb = liveIDs.contains(b.id)
            if la != lb { return la }
            return a.date > b.date
        }
    }

    var body: some View {
        let live = state.liveSessions.filter { $0.mood != .done }.count
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FlickView(mood: state.mood, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sessions").font(.system(size: 22, weight: .bold))
                    Text(live == 0 ? "Nothing running right now" : "\(live) running")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    FlickView(mood: .sleep, size: 90)
                    Text("No sessions yet").font(.headline)
                    Text("Sessions show up here as soon as Claude starts working.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(rows) { SessionRow(session: $0) }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ember.window)
        .modifier(FlickThemed())
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: rows)
    }
}

private struct SessionRow: View {
    @EnvironmentObject var state: AppState
    let session: SessionStatus

    private var isLive: Bool { session.mood == .working || session.mood == .needs }
    private var account: Account? { state.config.account(session.accountID) }
    private var cost: Double? {
        guard let id = session.location.sessionID else { return nil }
        return state.usage[session.accountID]?.costBySession()[id]
    }

    var body: some View {
        HStack(spacing: 12) {
            FlickView(mood: session.mood, size: 36, animated: isLive)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(state.config.color(for: session.accountID)).frame(width: 7, height: 7)
                    Text(account?.name ?? session.accountID)
                    Text("·")
                    Text(stateLabel).foregroundStyle(session.mood == .needs ? Ember.accent : .secondary)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if isLive {
                    Text(session.startedAt, style: .timer).font(.number(14, weight: .semibold)).monospacedDigit()
                } else {
                    Text(Self.duration(session.date.timeIntervalSince(session.startedAt))).font(.number(14, weight: .semibold))
                }
                Text(cost.map(Fmt.usd) ?? "—").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if session.location.appBundleID != nil {
                Button(isLive ? "Open" : "Go") { state.open(session) }
                    .buttonStyle(EmberButtonStyle())
                    .help("Take me to this session")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(session.mood == .needs ? Ember.alert : (isLive ? Ember.cardRaised : Ember.card)))
        .opacity(isLive || session.mood == .needs ? 1 : 0.8)
    }

    private var stateLabel: String {
        switch session.mood {
        case .working: return "Working"
        case .needs: return "Needs you"
        default: return "Finished \(session.date.formatted(.relative(presentation: .named)))"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
