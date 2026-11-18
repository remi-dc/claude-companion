import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            PersonalityTab().tabItem { Label("Flick", systemImage: "flame") }
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.2") }
            SoundsTab().tabItem { Label("Notifications", systemImage: "bell.badge") }
            AlertsTab().tabItem { Label("Alerts", systemImage: "exclamationmark.bubble") }
            ShortcutsTab().tabItem { Label("Shortcuts", systemImage: "command") }
            SetupTab().tabItem { Label("Setup", systemImage: "wrench.and.screwdriver") }
        }
        .padding(16)
        .modifier(FlickThemed())
    }
}

// MARK: Accounts

private struct AccountsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each account is a separate Claude Code config directory (`CLAUDE_CONFIG_DIR`), with its own login, settings and history.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(state.config.accounts) { account in
                    AccountEditor(account: account)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Button { state.addAccount() } label: { Label("Add account", systemImage: "plus") }
                Spacer()
                Text("After adding an account, re-run “Install hooks” in Setup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AccountEditor: View {
    @EnvironmentObject var state: AppState
    let account: Account

    private func binding<T>(_ kp: WritableKeyPath<Account, T>) -> Binding<T> {
        Binding(get: { state.config.account(account.id)?[keyPath: kp] ?? account[keyPath: kp] },
                set: { var a = state.config.account(account.id) ?? account; a[keyPath: kp] = $0; state.update(a) })
    }

    var body: some View {
        let _ = state.statusTick
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: account.symbol).font(.title2).frame(width: 30).padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Name", text: binding(\.name)).textFieldStyle(.roundedBorder).frame(width: 140)
                    TextField("SF Symbol", text: binding(\.symbol)).textFieldStyle(.roundedBorder).frame(width: 140)
                    if account.id == state.config.activeAccountID {
                        Text("Active").font(.caption).foregroundStyle(Color.accentColor)
                    } else {
                        Button("Make active") { state.activate(account.id) }.controlSize(.small)
                    }
                }
                TextField("Config directory", text: binding(\.configDir)).textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Picker("Sign in with", selection: binding(\.loginBrowser)) {
                    Text("Default browser").tag(String?.none)
                    ForEach(LoginBrowser.available()) { b in Text(b.label).tag(Optional(b.id)) }
                }
                .help("Claude's sign-in page (Log in… or /login) opens here, so this account uses the right browser profile.")
                HStack(spacing: 14) {
                    Label(account.loggedInEmail ?? "Not logged in",
                          systemImage: account.loggedInEmail == nil ? "xmark.circle" : "checkmark.seal")
                        .foregroundStyle(account.loggedInEmail == nil ? .orange : .secondary)
                    let upToDate = Integration.hooksUpToDate(for: account)
                    Label(upToDate ? "Hooks installed" : Integration.hooksInstalled(for: account) ? "Hooks need update" : "Hooks missing",
                          systemImage: upToDate ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(upToDate ? Color.secondary : Color.orange)
                    Spacer()
                    Button("Log in…") { Integration.openLoginTerminal(for: account) }
                        .help("Opens Terminal running Claude Code for this account — type /login")
                    Button(role: .destructive) { state.removeAccount(account.id) } label: { Image(systemName: "trash") }
                        .disabled(state.config.accounts.count <= 1)
                        .help("Remove from Companion (files on disk are kept)")
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: Sounds / notifications

private struct SoundsTab: View {
    @EnvironmentObject var state: AppState
    @State private var sounds = Sounds.available()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                Toggle("Pause all notifications", isOn: $state.config.paused)
                Toggle("Show Claude's last message in notifications", isOn: $state.config.showMessagePreview)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Account").font(.caption).foregroundStyle(.secondary)
                    ForEach(HookEvent.notifiable) { e in
                        Label(e.title, systemImage: e.symbol).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("On").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                ForEach(state.config.accounts) { account in
                    GridRow {
                        Label(account.name, systemImage: account.symbol)
                        ForEach(HookEvent.notifiable) { e in
                            HStack(spacing: 4) {
                                Picker("", selection: soundBinding(account, e)) {
                                    ForEach(sounds, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 110)
                                Button { state.sendTest(e, account: account) } label: { Image(systemName: "play.fill") }
                                    .buttonStyle(.borderless)
                                    .help("Send a test notification")
                            }
                        }
                        Toggle("", isOn: enabledBinding(account)).labelsHidden()
                    }
                }
            }

            HStack {
                Button("Add custom sound…", action: importSound)
                Text("Copied to ~/Library/Sounds. AIFF, WAV, MP3, M4A or CAF.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Give each account its own “Finished” sound so you know which one is done without looking. Permission requests are delivered as Time Sensitive.")
                .font(.caption).foregroundStyle(.secondary)
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

// MARK: Setup

private struct SetupTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: Updater

    var body: some View {
        let _ = state.statusTick
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Text("Claude Companion \(Updater.currentVersion)").font(.headline)
                    Spacer()
                    switch updater.phase {
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .failed(let message):
                        Text(message).font(.caption).foregroundStyle(.red)
                    default:
                        if let r = updater.available {
                            Text("Version \(r.version) is available").font(.caption).foregroundStyle(Ember.accent)
                            Button("Update") { Task { await updater.install() } }
                        } else if updater.lastChecked != nil {
                            Text("Up to date").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Check for updates") { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.phase == .checking)
                }
                Divider()

                step(0, "Allow notifications",
                     "macOS asks the first time the app launches. If you dismissed it, turn on Claude Companion in System Settings → Notifications. Until then you get plain AppleScript banners (listed as Script Editor); sounds play either way.") {
                    HStack {
                        switch state.notificationPermission {
                        case .allowed:
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .denied:
                            Label("Not allowed", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                        case .unknown:
                            Label("Not decided yet", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Notification Settings") { Notifier.openSystemSettings() }
                    }
                }

                step(1, "Notification hooks",
                     "Adds hooks to each account's settings.json: Stop and Notification for alerts, UserPromptSubmit and PostToolUse so Flick knows when Claude is working (including right after you approve a permission). They run in the background, so Claude never waits. A backup is saved next to the file, and existing settings and hooks are kept.") {
                    HStack {
                        let n = state.config.accounts.filter(Integration.hooksUpToDate).count
                        let stale = state.config.accounts.contains { Integration.hooksInstalled(for: $0) && !Integration.hooksUpToDate(for: $0) }
                        Button(stale ? "Update hooks" : "Install hooks") { state.installAllHooks() }.buttonStyle(.borderedProminent)
                        Button("Remove hooks") { state.removeAllHooks() }
                        Spacer()
                        Text("\(n)/\(state.config.accounts.count) accounts").font(.caption).foregroundStyle(.secondary)
                    }
                }

                step(2, "Account switching for the `claude` command",
                     "Installs a small `claude` wrapper in ~/.claude-companion/bin and puts it first on your PATH (one line in ~/.zshrc). Each new `claude` session then uses the account picked in the menu bar. Sessions already running keep their account.") {
                    HStack {
                        Button(Integration.wrapperInstalled && Integration.pathConfigured ? "Reinstall" : "Install shell integration") {
                            state.installShellIntegration()
                        }
                        Spacer()
                        Text(Integration.wrapperInstalled && Integration.pathConfigured ? "Installed — open a new terminal tab" : "Not installed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(Integration.zshrcLine)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }

                step(3, "Account switching in VS Code",
                     "Sets the Claude Code extension's `claudeCode.claudeProcessWrapper` setting to a small wrapper that applies the active account. Your editor settings keep their comments and formatting, and a backup is saved. After switching accounts, start a new Claude conversation (or run “Developer: Reload Window”).") {
                    if Integration.editorSettingsFiles.isEmpty {
                        Text("No VS Code-based editor found.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Integration.editorSettingsFiles, id: \.path) { editor in
                        HStack {
                            Text(editor.name)
                            Spacer()
                            if Integration.vscodeConfigured(editor.path) {
                                Label("Configured", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                                Button("Remove") { state.setVSCode(editor.path, enabled: false) }
                            } else {
                                Button("Configure") { state.setVSCode(editor.path, enabled: true) }
                            }
                        }
                    }
                }

                step(4, "Log in to each account",
                     "In the Accounts tab, click “Log in…” next to Work and Backup, then type /login in the Terminal window that opens.") { EmptyView() }

                step(5, "Test it", "Sends a sample of each notification for the active account.") {
                    HStack {
                        ForEach(HookEvent.notifiable) { e in
                            Button { state.sendTest(e, account: state.activeAccount) } label: {
                                Label(e.title, systemImage: e.symbol)
                            }
                        }
                    }
                }

                if let err = state.lastError {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }

                Text("The Claude desktop app always uses the default account (~/.claude). Hooks still notify for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .onAppear { state.refreshPermission() }
    }

    @ViewBuilder
    private func step<C: View>(_ n: Int, _ title: String, _ text: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 6) {
                Text(.init(title)).font(.headline)
                Text(.init(text)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}

// MARK: Flick

private struct PersonalityTab: View {
    @EnvironmentObject var state: AppState
    @State private var preview: FlickMood = .idle

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 14) {
                FlickView(mood: preview, size: 150)
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Ember.card))
                Picker("Preview", selection: $preview) {
                    ForEach(FlickMood.allCases, id: \.self) { Text($0.label.capitalized).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Meet Flick").font(.title2.weight(.semibold))
                Text("Flick is the little ember who keeps an eye on Claude for you. He flickers while Claude works, hops when a session needs your OK, and takes a nap when things are quiet.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $state.config.friendlyMessages) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Friendly messages")
                        Text(state.config.friendlyMessages
                             ? "Flick talks to you: “On it! Working on billing-api”."
                             : "Plain status text: “Working · billing-api”.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Divider()
                HStack(spacing: 10) {
                    Text("Color")
                    ForEach([("ember", "Ember", FlickPalette.ember), ("glacier", "Glacier", .glacier), ("mint", "Mint", .mint),
                             ("account", "Account", FlickPalette.from(state.config.color(for: state.activeAccount.id)))], id: \.0) { option in
                        let selected = state.config.flick.color == option.0
                        Button {
                            withAnimation(.spring(response: 0.3)) { state.config.flick.color = option.0 }
                        } label: {
                            VStack(spacing: 3) {
                                Circle()
                                    .fill(LinearGradient(colors: [option.2.top, option.2.bottom], startPoint: .top, endPoint: .bottom))
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Ember.accent, lineWidth: 2).padding(-3).opacity(selected ? 1 : 0))
                                Text(option.1).font(.caption2).foregroundStyle(selected ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(option.1)\(selected ? ", selected" : "")")
                    }
                }
                Picker("Size in the menu", selection: $state.config.flick.size) {
                    Text("Small").tag("small"); Text("Medium").tag("medium"); Text("Large").tag("large")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Toggle("Calm mode (keep Flick still)", isOn: $state.config.flick.calm)
                    .toggleStyle(.switch)
                Text("Flick also stays still when Reduce Motion is on in System Settings › Accessibility › Display.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Alerts

private struct AlertsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Each alert can be turned on or off. Alerts fire once per period and stay quiet while notifications are paused.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                alert("Monthly budget", "Warns at 80% and 100% of each account's budget for the month.",
                      isOn: $state.config.alerts.budgetEnabled) {
                    ForEach(state.config.accounts) { account in
                        HStack {
                            Circle().fill(state.config.color(for: account.id)).frame(width: 8, height: 8)
                            Text(account.name).frame(width: 90, alignment: .leading)
                            TextField("No budget", value: budgetBinding(account.id), format: .currency(code: "USD"))
                                .textFieldStyle(.roundedBorder).frame(width: 110)
                            Text("per month").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                alert("Busy 5-hour window", "Tells you when the current window has used more than a set amount.",
                      isOn: $state.config.alerts.windowEnabled) {
                    HStack {
                        Text("Alert above")
                        TextField("", value: $state.config.alerts.windowThreshold, format: .currency(code: "USD"))
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                        Text("in one window").font(.caption).foregroundStyle(.secondary)
                    }
                }

                alert("Window reset", "Tells you when a busy 5-hour window resets, so you know you can pick up again.",
                      isOn: $state.config.alerts.resetEnabled) { EmptyView() }

                alert("Daily summary", "Sessions, cost and your most active project, once a day.",
                      isOn: $state.config.alerts.summaryEnabled) {
                    Picker("Send at", selection: $state.config.alerts.summaryHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!
                                    .formatted(date: .omitted, time: .shortened)).tag(h)
                        }
                    }
                    .frame(width: 180)
                }
            }
            .padding(4)
        }
    }

    private func budgetBinding(_ id: String) -> Binding<Double?> {
        Binding(get: { state.config.alerts.budgets[id] },
                set: { state.config.alerts.budgets[id] = ($0 ?? 0) > 0 ? $0 : nil })
    }

    @ViewBuilder
    private func alert<C: View>(_ title: String, _ detail: String, isOn: Binding<Bool>, @ViewBuilder options: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn.animation(.easeInOut(duration: 0.2))) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if isOn.wrappedValue {
                options().padding(.leading, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ember.card))
    }
}

// MARK: Shortcuts

private struct ShortcutsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shortcuts work everywhere on your Mac. Click one and press the keys you want; the x turns it off.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                ForEach(Shortcut.actions, id: \.id) { action in
                    GridRow {
                        Text(title(for: action))
                        ShortcutRecorder(shortcut: binding(action.id))
                        if state.shortcutConflicts.contains(action.id) {
                            Label("Used by another app", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("")
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Restore defaults") { state.config.shortcuts = Shortcut.defaults }
            }
            Spacer()
        }
        .padding(4)
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
