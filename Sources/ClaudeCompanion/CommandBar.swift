import AppKit
import SwiftUI

/// A Spotlight-like bar to ask Claude anything, from anywhere: pick a project, get a quick answer
/// right here, or open a full session in Terminal, on the right account.
@MainActor
final class CommandBar {
    static let shared = CommandBar()
    let model = CommandModel()
    private var panel: KeyPanel?
    private weak var state: AppState?

    func toggle(_ state: AppState) {
        self.state = state
        if let panel, panel.isVisible { hide(); return }
        show(state)
    }

    func show(_ state: AppState) {
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
                             styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = FirstClickHostingView(rootView: CommandBarView()
                .modifier(FlickThemed())
                .environmentObject(state).environmentObject(model))
            p.onResignKey = { [weak self] in
                guard let self, !self.model.running, self.model.answer == nil else { return }
                self.hide()
            }
            panel = p
        }
        HistoryIndex.shared.refresh(accounts: state.config.accounts)
        model.prepare(state)
        guard let panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 330, y: f.maxY - f.height * 0.18))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.focusToken &+= 1
    }

    func hide() {
        panel?.orderOut(nil)
        model.reset()
    }
}

final class KeyPanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

@MainActor
final class CommandModel: ObservableObject {
    @Published var prompt = ""
    @Published var projectPath: String?
    /// nil: decide automatically (folder rule, then the project's last account, then the active one).
    @Published var accountID: String?
    @Published var mode = "quick"
    @Published private(set) var running = false
    @Published private(set) var answer: String?
    @Published private(set) var error: String?
    @Published var focusToken = 0
    private var process: Process?

    func prepare(_ state: AppState) {
        if projectPath == nil { projectPath = HistoryIndex.shared.projects.first?.path }
    }

    func reset() {
        if running { return }
        prompt = ""
        answer = nil
        error = nil
        accountID = nil
    }

    func account(_ state: AppState) -> Account {
        if let id = accountID, let a = state.config.account(id) { return a }
        guard let path = projectPath else { return state.activeAccount }
        return state.config.ruleAccount(for: path)
            ?? HistoryIndex.shared.projects.first(where: { $0.path == path })?.accountIDs.first.flatMap { state.config.account($0) }
            ?? state.activeAccount
    }

    func run(_ state: AppState) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        let folder = projectPath ?? Paths.home
        let account = account(state)

        if mode == "session" {
            TerminalLauncher.launch(in: folder, account: account, arguments: [text], name: "command-session")
            CommandBar.shared.hide()
            return
        }

        guard let claude = Integration.findClaude() else {
            error = "Claude Code wasn't found on this Mac."
            return
        }
        answer = nil
        error = nil
        running = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["-p", text]
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        var env = ProcessInfo.processInfo.environment
        if account.isDefaultDir { env.removeValue(forKey: "CLAUDE_CONFIG_DIR") } else { env["CLAUDE_CONFIG_DIR"] = account.expandedConfigDir }
        env["CLAUDE_COMPANION_BYPASS"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = proc.terminationStatus
            Task { @MainActor in
                self.running = false
                self.process = nil
                let answer = o.trimmingCharacters(in: .whitespacesAndNewlines)
                if status == 0 || !answer.isEmpty { self.answer = answer.isEmpty ? "(No answer)" : answer }
                else if status != 15 { self.error = e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Claude stopped (code \(status))." : String(e.prefix(400)) }
            }
        }
        do { try p.run(); process = p } catch { running = false; self.error = error.localizedDescription }
    }

    /// Demo screenshots only.
    func showDemo(prompt: String, answer: String) { self.prompt = prompt; self.answer = answer }

    func cancel() {
        process?.terminate()
        running = false
    }
}

private struct CommandBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var model: CommandModel
    @ObservedObject private var index = HistoryIndex.shared
    @FocusState private var focused: Bool

    var body: some View {
        let account = model.account(state)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                FlickView(mood: model.running ? .working : (model.answer != nil ? .done : .idle), size: 34)
                TextField(model.mode == "quick" ? "Ask Claude anything…" : "What should Claude work on?", text: $model.prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { model.run(state) }
                    .disabled(model.running)
                if model.running {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.cancel() }.buttonStyle(EmberPillStyle()).keyboardShortcut(".", modifiers: .command)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Menu {
                    ForEach(index.projects.prefix(15)) { p in
                        Button(p.name) { model.projectPath = p.path; model.accountID = nil }
                    }
                    Divider()
                    Button("Choose a Folder…") { chooseFolder() }
                } label: {
                    Label(model.projectPath.map { ($0 as NSString).lastPathComponent } ?? "No project", systemImage: "folder")
                }
                .menuStyle(.borderlessButton).fixedSize()

                Menu {
                    Button("Automatic (\(model.account(state).name))") { model.accountID = nil }
                    Divider()
                    ForEach(state.config.accounts) { a in Button(a.name) { model.accountID = a.id } }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(state.config.color(for: account.id)).frame(width: 8, height: 8)
                        Text(account.name)
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Folder rules decide automatically; pick one to override")

                Spacer()
                Picker("", selection: $model.mode) {
                    Text("Quick answer").tag("quick")
                    Text("Open session").tag("session")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16).padding(.vertical, 9)

            if let answer = model.answer {
                Divider().opacity(0.5)
                ScrollView {
                    Text(.init(answer))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
                .frame(maxHeight: 280)
                HStack {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer, forType: .string) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        let a = model.account(state)
                        TerminalLauncher.launch(in: model.projectPath ?? Paths.home, account: a, arguments: ["--continue"], name: "command-continue")
                        CommandBar.shared.hide()
                    } label: { Label("Continue in Terminal", systemImage: "terminal") }
                    Spacer()
                    Button("New Question") { model.reset(); focused = true }.keyboardShortcut("n", modifiers: .command)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
        }
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .tint(Ember.accent)
        .onExitCommand { CommandBar.shared.hide() }
        .onChange(of: model.focusToken) { focused = true }
        .onAppear { focused = true }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.projectPath = url.path
        model.accountID = nil
    }
}
