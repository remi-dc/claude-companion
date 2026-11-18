import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.2") }
            SoundsTab().tabItem { Label("Notifications", systemImage: "bell.badge") }
            SetupTab().tabItem { Label("Setup", systemImage: "wrench.and.screwdriver") }
        }
        .padding(16)
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
                HStack(spacing: 14) {
                    Label(account.loggedInEmail ?? "Not logged in",
                          systemImage: account.loggedInEmail == nil ? "xmark.circle" : "checkmark.seal")
                        .foregroundStyle(account.loggedInEmail == nil ? .orange : .secondary)
                    Label(Integration.hooksInstalled(for: account) ? "Hooks installed" : "Hooks missing",
                          systemImage: Integration.hooksInstalled(for: account) ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(Integration.hooksInstalled(for: account) ? Color.secondary : Color.orange)
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
                    ForEach(HookEvent.allCases) { e in
                        Label(e.title, systemImage: e.symbol).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("On").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                ForEach(state.config.accounts) { account in
                    GridRow {
                        Label(account.name, systemImage: account.symbol)
                        ForEach(HookEvent.allCases) { e in
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

    var body: some View {
        let _ = state.statusTick
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
                     "Adds Stop and Notification hooks to each account's settings.json (a backup is saved next to it). Existing settings and hooks are kept.") {
                    HStack {
                        Button("Install hooks") { state.installAllHooks() }.buttonStyle(.borderedProminent)
                        Button("Remove hooks") { state.removeAllHooks() }
                        Spacer()
                        let n = state.config.accounts.filter(Integration.hooksInstalled).count
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

                step(3, "Log in to each account",
                     "In the Accounts tab, click “Log in…” next to Work and Backup, then type /login in the Terminal window that opens.") { EmptyView() }

                step(4, "Test it", "Sends a sample of each notification for the active account.") {
                    HStack {
                        ForEach(HookEvent.allCases) { e in
                            Button { state.sendTest(e, account: state.activeAccount) } label: {
                                Label(e.title, systemImage: e.symbol)
                            }
                        }
                    }
                }

                if let err = state.lastError {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }

                Text("The VS Code extension and Claude desktop app don't go through the `claude` wrapper, so they keep using the default account (~/.claude). Hooks still notify for them.")
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
