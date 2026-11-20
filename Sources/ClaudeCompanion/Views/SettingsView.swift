import SwiftUI
import UniformTypeIdentifiers

// MARK: Window

/// System Settings-style window: a sidebar of panes, each a native grouped form.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var pane: Pane = Demo.settingsPane.flatMap(Pane.init(rawValue:)) ?? .general

    enum Pane: String, CaseIterable, Identifiable {
        case general, notch, accounts, switching, notifications, alerts, shortcuts, setup, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .notch: return "Notch"
            case .accounts: return "Accounts"
            case .switching: return "Switching"
            case .notifications: return "Notifications"
            case .alerts: return "Alerts"
            case .shortcuts: return "Shortcuts"
            case .setup: return "Setup"
            case .about: return "About"
            }
        }

        var icon: (symbol: String, color: Color) {
            switch self {
            case .general: return ("flame.fill", Color(hex: 0xE2774D))
            case .notch: return ("rectangle.topthird.inset.filled", Color(hex: 0x1D1D1F))
            case .accounts: return ("person.2.fill", Color(hex: 0x2A78D6))
            case .switching: return ("arrow.triangle.branch", Color(hex: 0x6250D6))
            case .notifications: return ("bell.badge.fill", Color(hex: 0xE34948))
            case .alerts: return ("gauge.with.dots.needle.67percent", Color(hex: 0xE59A00))
            case .shortcuts: return ("command", Color(hex: 0x6E6E73))
            case .setup: return ("checklist", Color(hex: 0x1BAF7A))
            case .about: return ("info", Color(hex: 0x8E8E93))
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                SidebarHeader().listRowSeparator(.hidden)
                ForEach(Pane.allCases) { p in
                    HStack(spacing: 9) {
                        SettingsIcon(symbol: p.icon.symbol, color: p.icon.color)
                        Text(p.title)
                        Spacer()
                        if p == .setup, SetupStatus(state: state).missing > 0 {
                            Circle().fill(Color.orange).frame(width: 8, height: 8)
                                .accessibilityLabel("Setup needs attention")
                        }
                    }
                    .tag(p)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane()
                case .notch: NotchPane()
                case .accounts: AccountsPane()
                case .switching: SwitchingPane()
                case .notifications: NotificationsPane()
                case .alerts: AlertsPane()
                case .shortcuts: ShortcutsPane()
                case .setup: SetupPane()
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .tint(Ember.accent)
        .modifier(FlickThemed())
    }
}

/// The colored rounded-square icons of System Settings.
private struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
    }
}

private struct SidebarHeader: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 10) {
            FlickView(mood: state.mood, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Companion").font(.system(size: 13, weight: .semibold))
                Text(state.statusLine.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .selectionDisabled()
    }
}

/// A row title with a secondary line underneath, for Form rows.
private struct RowLabel: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

// MARK: General

private struct GeneralPane: View {
    @EnvironmentObject var state: AppState
    @State private var preview: FlickMood = .working

    var body: some View {
        Form {
            Section {
                HStack(spacing: 20) {
                    FlickView(mood: preview, size: 110)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ember.card))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Meet Flick").font(.title3.weight(.semibold))
                        Text("The little ember who keeps an eye on Claude for you. He flickers while Claude works, hops when a session needs your OK and naps when things are quiet.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Picker("Preview", selection: $preview) {
                            ForEach(FlickMood.allCases, id: \.self) { Text($0.label.capitalized).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Personality") {
                Toggle(isOn: $state.config.friendlyMessages) {
                    RowLabel(title: "Friendly messages",
                             detail: state.config.friendlyMessages ? "“On it! Working on billing-api”" : "“Working · billing-api”")
                }
                Toggle(isOn: $state.config.flick.calm) {
                    RowLabel(title: "Calm mode", detail: "Keep Flick still. He also stays still when Reduce Motion is on.")
                }
            }

            Section("Appearance") {
                LabeledContent("Color") {
                    HStack(spacing: 14) {
                        ForEach(colorOptions, id: \.id) { option in
                            let selected = state.config.flick.color == option.id
                            Button {
                                withAnimation(.spring(response: 0.3)) { state.config.flick.color = option.id }
                            } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(LinearGradient(colors: [option.palette.top, option.palette.bottom], startPoint: .top, endPoint: .bottom))
                                        .frame(width: 22, height: 22)
                                        .overlay(Circle().stroke(Ember.accent, lineWidth: 2).padding(-3).opacity(selected ? 1 : 0))
                                    Text(option.name).font(.caption2).foregroundStyle(selected ? .primary : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(option.name)\(selected ? ", selected" : "")")
                        }
                    }
                }
                Picker("Size in the menu", selection: $state.config.flick.size) {
                    Text("Small").tag("small"); Text("Medium").tag("medium"); Text("Large").tag("large")
                }
                .pickerStyle(.segmented)
            }

            Section("Menu bar") {
                Picker(selection: $state.config.menuBarAccount) {
                    Text("Name").tag("name")
                    Text("Color dot").tag("dot")
                    Text("Nothing").tag("off")
                } label: {
                    RowLabel(title: "Show the active account", detail: "Its name (like “School”) next to the icon, or a dot in its color.")
                }
            }
        }
    }

    private var colorOptions: [(id: String, name: String, palette: FlickPalette)] {
        [("ember", "Ember", .ember), ("glacier", "Glacier", .glacier), ("mint", "Mint", .mint),
         ("account", "Account", .from(state.config.color(for: state.activeAccount.id)))]
    }
}

// MARK: Accounts

private struct AccountsPane: View {
    @EnvironmentObject var state: AppState
    @State private var selected: String?

    private var account: Account? {
        state.config.account(selected ?? "") ?? state.config.accounts.first
    }

    var body: some View {
        let _ = state.statusTick
        Form {
            Section {
                HStack(spacing: 10) {
                    ForEach(state.config.accounts) { a in
                        let isSelected = a.id == account?.id
                        Button { withAnimation(.spring(response: 0.3)) { selected = a.id } } label: {
                            VStack(spacing: 6) {
                                Circle().fill(state.config.color(for: a.id)).frame(width: 40, height: 40)
                                    .overlay(Image(systemName: a.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
                                    .overlay(Circle().stroke(state.config.color(for: a.id), lineWidth: 2).padding(-4).opacity(isSelected ? 1 : 0))
                                Text(a.name).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                if a.id == state.config.activeAccountID {
                                    Text("Active").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ember.accent)
                                } else {
                                    Text(" ").font(.system(size: 10))
                                }
                            }
                            .frame(width: 84)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(isSelected ? Ember.card : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button { state.addAccount(); selected = state.config.accounts.last?.id } label: {
                        VStack(spacing: 6) {
                            Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4])).foregroundStyle(.secondary)
                                .frame(width: 40, height: 40)
                                .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                            Text("Add").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(" ").font(.system(size: 10))
                        }
                        .frame(width: 84).padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add an account")
                }
            } footer: {
                Text("Each account is its own Claude Code folder, with its own login, settings and history.")
            }

            if let account {
                AccountDetail(account: account)
            }
        }
    }
}

private struct AccountDetail: View {
    @EnvironmentObject var state: AppState
    let account: Account

    private static let symbols = ["person.fill", "briefcase.fill", "externaldrive.fill", "house.fill", "graduationcap.fill",
                                  "building.2.fill", "star.fill", "bolt.fill", "hammer.fill", "flask.fill", "heart.fill", "globe"]

    private func binding<T>(_ kp: WritableKeyPath<Account, T>) -> Binding<T> {
        Binding(get: { state.config.account(account.id)?[keyPath: kp] ?? account[keyPath: kp] },
                set: { var a = state.config.account(account.id) ?? account; a[keyPath: kp] = $0; state.update(a) })
    }

    var body: some View {
        let email = account.loggedInEmail
        let hooks = Integration.hooksUpToDate(for: account) ? "Installed" : Integration.hooksInstalled(for: account) ? "Needs update" : "Not installed"

        Section(account.name) {
            TextField("Name", text: binding(\.name))
            LabeledContent("Icon") {
                Menu {
                    ForEach(Self.symbols, id: \.self) { s in
                        Button { var a = account; a.symbol = s; state.update(a) } label: { Label(s, systemImage: s) }
                    }
                } label: {
                    Image(systemName: account.symbol)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            LabeledContent("Folder") {
                HStack(spacing: 6) {
                    Text(account.configDir).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: account.expandedConfigDir) } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
            Picker(selection: binding(\.loginBrowser)) {
                Text("Default browser").tag(String?.none)
                ForEach(LoginBrowser.available()) { b in Text(b.label).tag(Optional(b.id)) }
            } label: {
                RowLabel(title: "Sign in with", detail: "Where Log in… and /login open the sign-in page.")
            }
        }

        Section("Status") {
            LabeledContent("Signed in") {
                HStack(spacing: 8) {
                    Label(email ?? "Not signed in", systemImage: email == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(email == nil ? Color.orange : Color.green)
                        .labelStyle(.titleAndIcon)
                    Button("Log in…") { Integration.openLoginTerminal(for: account) }
                }
            }
            LabeledContent("Hooks") {
                Label(hooks, systemImage: hooks == "Installed" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(hooks == "Installed" ? Color.green : Color.orange)
            }
        }

        Section {
            HStack {
                if account.id == state.config.activeAccountID {
                    Label("Active account", systemImage: "checkmark").foregroundStyle(.secondary)
                } else {
                    Button("Make active") { withAnimation { state.activate(account.id) } }
                }
                Spacer()
                Button("Remove Account…", role: .destructive) { state.removeAccount(account.id) }
                    .disabled(state.config.accounts.count <= 1)
                    .help("Removes it from Claude Companion. Its folder, login and history stay on disk.")
            }
        }
    }
}

// MARK: Switching

private struct SwitchingPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                if state.config.folderRules.isEmpty {
                    Text("No folder rules yet.").foregroundStyle(.secondary)
                }
                ForEach($state.config.folderRules) { $rule in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(state.config.color(for: rule.accountID))
                        Text(rule.folder.replacingOccurrences(of: Paths.home, with: "~"))
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Picker("", selection: $rule.accountID) {
                            ForEach(state.config.accounts) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                        Button { state.config.folderRules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove rule")
                    }
                }
                Button { addRule() } label: { Label("Add Folder…", systemImage: "plus") }
            } header: {
                Text("Folder rules")
            } footer: {
                Text("Projects inside these folders always use their account, whatever is picked in the menu bar. The deepest folder wins.")
            }

            Section {
                Picker(selection: $state.config.reminderHours) {
                    Text("Never").tag(0)
                    ForEach([1, 2, 4, 8, 12, 24], id: \.self) { Text("After \($0) h").tag($0) }
                } label: {
                    RowLabel(title: "Confirm the account after a break")
                }
            } header: {
                Text("After a break")
            } footer: {
                Text("In the terminal, `claude` asks which account to use (Enter keeps it). In editors, a card shows the account of the new conversation, with a button to switch.")
            }
        }
    }

    private func addRule() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.config.folderRules.append(FolderRule(folder: url.path, accountID: state.activeAccount.id))
    }
}

// MARK: Notifications

private struct NotificationsPane: View {
    @EnvironmentObject var state: AppState
    @State private var sounds = Sounds.available()

    var body: some View {
        Form {
            Section {
                Toggle("Pause all notifications", isOn: $state.config.paused)
                Toggle("Show Claude's last message", isOn: $state.config.showMessagePreview)
            }

            Section {
                ForEach(HookEvent.notifiable) { e in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Picker("", selection: styleBinding(e)) {
                                Text("Disappears").tag("banner")
                                Text("Stays").tag("sticky")
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            Button { state.sendTest(e, account: state.activeAccount) } label: { Image(systemName: "play.circle") }
                                .buttonStyle(.borderless)
                                .help("Send a test")
                        }
                    } label: {
                        Label(e.title, systemImage: e.symbol)
                    }
                }
            } header: {
                Text("Style")
            } footer: {
                Text("“Stays” shows a card in the top-right corner until you click it; it clears itself once the session moves on. “Disappears” uses a normal macOS banner.")
            }

            ForEach(state.config.accounts) { account in
                Section {
                    Toggle("Notifications", isOn: enabledBinding(account))
                    if account.notificationsEnabled {
                        ForEach(HookEvent.notifiable) { e in
                            Picker(e.title, selection: soundBinding(account, e)) {
                                ForEach(sounds, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(state.config.color(for: account.id)).frame(width: 8, height: 8)
                        Text("\(account.name) sounds")
                    }
                }
            }

            Section {
                Button("Add Custom Sound…", action: importSound)
            } footer: {
                Text("Give each account its own “Finished” sound to tell them apart without looking. Custom sounds are copied to ~/Library/Sounds.")
            }
        }
    }

    private func soundBinding(_ account: Account, _ e: HookEvent) -> Binding<String> {
        Binding(get: { state.config.account(account.id)?.sound(for: e) ?? "None" },
                set: { new in
                    guard var a = state.config.account(account.id) else { return }
                    a.sounds[e.rawValue] = new
                    state.update(a)
                    Sounds.play(new)
                })
    }

    private func styleBinding(_ e: HookEvent) -> Binding<String> {
        Binding(get: { state.config.notificationStyles[e.rawValue] ?? "banner" },
                set: { state.config.notificationStyles[e.rawValue] = $0 })
    }

    private func enabledBinding(_ account: Account) -> Binding<Bool> {
        Binding(get: { state.config.account(account.id)?.notificationsEnabled ?? true },
                set: { guard var a = state.config.account(account.id) else { return }
                    a.notificationsEnabled = $0; state.update(a) })
    }

    private func importSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { _ = Sounds.importCustom(url) }
        sounds = Sounds.available()
    }
}

// MARK: Alerts

private struct AlertsPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $state.config.alerts.budgetEnabled.animation()) {
                    RowLabel(title: "Monthly budget", detail: "At 80% and 100% of each account's budget.")
                }
                if state.config.alerts.budgetEnabled {
                    ForEach(state.config.accounts) { account in
                        LabeledContent {
                            TextField("No budget", value: budgetBinding(account.id), format: .currency(code: "USD"))
                                .multilineTextAlignment(.trailing).frame(width: 110)
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(state.config.color(for: account.id)).frame(width: 8, height: 8)
                                Text(account.name)
                            }
                        }
                    }
                }
            }

            Section {
                Toggle(isOn: $state.config.alerts.windowEnabled.animation()) {
                    RowLabel(title: "Busy 5-hour window", detail: "When the current window goes over an amount.")
                }
                if state.config.alerts.windowEnabled {
                    LabeledContent("Alert above") {
                        TextField("", value: $state.config.alerts.windowThreshold, format: .currency(code: "USD"))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                    }
                }
            }

            Section {
                Toggle(isOn: $state.config.alerts.resetEnabled) {
                    RowLabel(title: "Window reset", detail: "When a busy 5-hour window resets, so you know you can pick up again.")
                }
            }

            Section {
                Toggle(isOn: $state.config.alerts.summaryEnabled.animation()) {
                    RowLabel(title: "Daily summary", detail: "Sessions, cost and your most active project.")
                }
                if state.config.alerts.summaryEnabled {
                    Picker("Send at", selection: $state.config.alerts.summaryHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
                                    .formatted(date: .omitted, time: .shortened)).tag(h)
                        }
                    }
                }
            } footer: {
                Text("Each alert fires once per period and stays quiet while notifications are paused.")
            }
        }
    }

    private func budgetBinding(_ id: String) -> Binding<Double?> {
        Binding(get: { state.config.alerts.budgets[id] },
                set: { state.config.alerts.budgets[id] = ($0 ?? 0) > 0 ? $0 : nil })
    }
}

// MARK: Shortcuts

private struct ShortcutsPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                ForEach(Shortcut.actions, id: \.id) { action in
                    LabeledContent {
                        HStack(spacing: 8) {
                            if state.shortcutConflicts.contains(action.id) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help("Another app already uses this shortcut")
                            }
                            ShortcutRecorder(shortcut: binding(action.id))
                        }
                    } label: {
                        Text(title(for: action))
                    }
                }
            } footer: {
                Text("Shortcuts work everywhere on your Mac. Click one and press the keys; Esc cancels, the × turns it off.")
            }
            Section {
                Button("Restore Defaults") { state.config.shortcuts = Shortcut.defaults }
            }
        }
    }

    private func title(for action: (id: String, title: String)) -> String {
        if action.id.hasPrefix("account"), let i = Int(action.id.suffix(1)) {
            return i <= state.config.accounts.count ? "Switch to \(state.config.accounts[i - 1].name)" : "Switch to account \(i)"
        }
        return action.title
    }

    private func binding(_ id: String) -> Binding<Shortcut?> {
        Binding(get: { state.config.shortcuts[id] }, set: { state.config.shortcuts[id] = $0 })
    }
}

// MARK: Setup

/// What's left to set up, for the sidebar dot and the checklist.
@MainActor
private struct SetupStatus {
    let state: AppState
    var notificationsOK: Bool { state.notificationPermission == .allowed }
    var hooksOK: Bool { state.config.accounts.allSatisfy(Integration.hooksUpToDate) }
    var missing: Int { (notificationsOK ? 0 : 1) + (hooksOK ? 0 : 1) }
}

private struct SetupPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let _ = state.statusTick
        let status = SetupStatus(state: state)
        let staleHooks = state.config.accounts.contains { Integration.hooksInstalled(for: $0) && !Integration.hooksUpToDate(for: $0) }
        let shellOK = Integration.wrapperInstalled && Integration.pathConfigured

        Form {
            Section {
                CheckRow(done: status.notificationsOK, title: "Notifications allowed",
                         detail: status.notificationsOK ? nil : "Until then, alerts show as plain “Script Editor” banners.") {
                    Button("Open Settings…") { Notifier.openSystemSettings() }
                }
                CheckRow(done: status.hooksOK, title: "Claude Code hooks",
                         detail: status.hooksOK ? "Installed for every account." : "Let Claude Code tell the app what's happening.") {
                    if status.hooksOK {
                        Button("Remove") { state.removeAllHooks() }
                    } else {
                        Button(staleHooks ? "Update" : "Install") { state.installAllHooks() }.buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                Text("Required")
            }

            Section {
                CheckRow(done: shellOK, title: "`claude` command", optional: true,
                         detail: shellOK ? "Follows the active account. Open a new terminal tab after installing." : "Adds one line to ~/.zshrc.") {
                    Button(shellOK ? "Reinstall" : "Install") { state.installShellIntegration() }
                }
                ForEach(Integration.editorSettingsFiles, id: \.path) { editor in
                    let on = Integration.vscodeConfigured(editor.path)
                    CheckRow(done: on, title: editor.name, optional: true,
                             detail: on ? "The Claude Code extension follows the active account." : nil) {
                        Button(on ? "Remove" : "Configure") { state.setVSCode(editor.path, enabled: !on) }
                    }
                }
            } header: {
                Text("Account switching")
            } footer: {
                Text("The Claude desktop app always uses Personal (~/.claude). Notifications still work for it.")
            }

            Section("Accounts") {
                ForEach(state.config.accounts) { account in
                    let email = account.loggedInEmail
                    CheckRow(done: email != nil, title: account.name, detail: email ?? "Not signed in") {
                        Button("Log in…") { Integration.openLoginTerminal(for: account) }
                    }
                }
            }

            Section("Try it") {
                HStack {
                    ForEach(HookEvent.notifiable) { e in
                        Button { state.sendTest(e, account: state.activeAccount) } label: { Label(e.title, systemImage: e.symbol) }
                    }
                }
                if let err = state.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
        }
        .onAppear { state.refreshPermission() }
    }
}

private struct CheckRow<Action: View>: View {
    let done: Bool
    let title: String
    var optional = false
    var detail: String? = nil
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : (optional ? "circle" : "exclamationmark.circle.fill"))
                .font(.system(size: 17))
                .foregroundStyle(done ? Color.green : (optional ? Color.secondary : Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(.init(title))
                if let detail { Text(.init(detail)).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            action
        }
    }
}

// MARK: About

private struct AboutPane: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claude Companion").font(.title2.weight(.semibold))
                        Text("Version \(Updater.currentVersion)").foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Link("GitHub", destination: URL(string: "https://github.com/\(Updater.repo)")!)
                            Link("Release notes", destination: URL(string: "https://github.com/\(Updater.repo)/releases")!)
                        }
                        .font(.callout)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Updates") {
                LabeledContent {
                    HStack(spacing: 8) {
                        switch updater.phase {
                        case .checking, .downloading, .installing: ProgressView().controlSize(.small)
                        default: EmptyView()
                        }
                        if let r = updater.available {
                            Button("Update to \(r.version)") { Task { await updater.install() } }.buttonStyle(.borderedProminent)
                        } else {
                            Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                                .disabled(updater.phase == .checking)
                        }
                    }
                } label: {
                    RowLabel(title: statusText, detail: updater.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))" })
                }
            }

            Section {
                Text("Unofficial community project, not affiliated with or endorsed by Anthropic. MIT licensed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        if case .failed(let message) = updater.phase { return message }
        if let r = updater.available { return "Version \(r.version) is available" }
        return updater.lastChecked == nil ? "Checks every few hours" : "You're up to date"
    }
}

// MARK: Notch

private struct NotchPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("Show Claude Companion in", selection: $state.config.notch.presentation) {
                    Text("Menu bar").tag("menubar")
                    Text("Notch").tag("notch")
                    Text("Both").tag("both")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("The notch grows out of your MacBook's notch: Flick sits beside it, it widens while Claude works, drops down when a session needs you, and opens with your tools when you hover it. On screens without a notch it's a small pill at the top center.")
            }

            if state.config.notch.notchOn {
                Section("Behavior") {
                    Toggle(isOn: $state.config.notch.notificationsInNotch) {
                        RowLabel(title: "Show notifications in the notch", detail: "Instead of macOS banners. Sounds still play, and each one has a button to jump to the session.")
                    }
                    Toggle(isOn: $state.config.notch.liveActivity) {
                        RowLabel(title: "Show what Claude is doing", detail: "“Editing parser.swift”, “Running npm test”… under the notch while it works.")
                    }
                    Picker("Screen", selection: $state.config.notch.screen) {
                        Text("Built-in display").tag("builtin")
                        Text("The one with the pointer").tag("pointer")
                    }
                    Toggle(isOn: $state.config.notch.privateWhenMirroring) {
                        RowLabel(title: "Hide private things while mirroring", detail: "Projects, messages, clipboard and shelf stay hidden when your display is mirrored, e.g. on a projector.")
                    }
                }

                Section {
                    Toggle(isOn: $state.config.notch.musicTab) { Label("Music", systemImage: "music.note") }
                    Toggle(isOn: $state.config.notch.calendarTab) { Label("Calendar", systemImage: "calendar") }
                    Toggle(isOn: $state.config.notch.shelfTab) { Label("Shelf", systemImage: "tray.full") }
                    Toggle(isOn: $state.config.notch.clipboardTab) { Label("Clipboard", systemImage: "doc.on.clipboard") }
                } header: {
                    Text("Tabs")
                } footer: {
                    Text("Music works with Music and Spotify (macOS asks once to let Claude Companion control them). Calendar asks for access the first time. The clipboard history stays in memory and skips anything apps mark as a password.")
                }
            }
        }
    }
}
