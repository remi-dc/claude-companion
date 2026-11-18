import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude Companion").font(.headline)
                Spacer()
                Toggle(isOn: Binding(get: { !state.config.paused }, set: { state.config.paused = !$0 })) {
                    Image(systemName: state.config.paused ? "bell.slash" : "bell")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(state.config.paused ? "Notifications paused" : "Notifications on")
            }

            // Account switcher
            VStack(spacing: 2) {
                ForEach(state.config.accounts) { account in
                    AccountRow(account: account, isActive: account.id == state.config.activeAccountID) {
                        state.activate(account.id)
                    }
                }
            }
            Text("New `claude` sessions use the active account.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()

            // Usage glance for active account
            let u = state.usage[state.activeAccount.id] ?? .empty
            HStack(spacing: 8) {
                if let block = u.currentBlock {
                    MiniStat(title: "5h window", value: Fmt.usd(block.cost),
                             detail: "resets in \(Fmt.remaining(until: block.end))")
                } else {
                    MiniStat(title: "5h window", value: "—", detail: "no active window")
                }
                MiniStat(title: "Today", value: Fmt.usd(u.cost(since: Calendar.current.startOfDay(for: Date()))),
                         detail: Fmt.tokens(u.tokens(since: Calendar.current.startOfDay(for: Date()))) + " tokens")
            }

            if !state.recent.isEmpty {
                Divider()
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                ForEach(state.recent.prefix(4)) { msg in
                    RecentRow(msg: msg, accountName: state.config.account(msg.accountID)?.name ?? msg.accountID)
                }
            }

            Divider()
            HStack {
                Button { open("dashboard") } label: { Label("Dashboard", systemImage: "chart.bar.xaxis") }
                Button { open("settings") } label: { Label("Settings", systemImage: "gearshape") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func open(_ id: String) {
        WindowManager.shared.show(id, state: state)
    }
}

private struct AccountRow: View {
    let account: Account
    let isActive: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: account.symbol)
                    .frame(width: 18)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name).fontWeight(isActive ? .semibold : .regular)
                    Text(account.loggedInEmail ?? "Not logged in")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if isActive { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover || isActive ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct MiniStat: View {
    let title: String, value: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit()).fontWeight(.semibold)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

private struct RecentRow: View {
    let msg: HookMessage
    let accountName: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: msg.event.symbol).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(msg.event.title) · \(msg.project)").font(.caption).lineLimit(1)
                Text("\(accountName) · \(msg.date.formatted(.relative(presentation: .named)))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
