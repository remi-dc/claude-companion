import AppKit
import SwiftUI

/// Projects hub and conversation history: every project, every conversation, searchable, resumable.
struct ProjectsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var index = HistoryIndex.shared
    @State private var selection: String?
    @State private var query = ""

    var body: some View {
        let projects = index.projects
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(projects) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            ForEach(p.accountIDs, id: \.self) { MiniTag(accountID: $0) }
                            Text(p.lastDate.formatted(.relative(presentation: .named)))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(p.path)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
            .overlay {
                if projects.isEmpty {
                    VStack(spacing: 8) {
                        if index.isIndexing { ProgressView() }
                        Text(index.isIndexing ? "Reading your history…" : "No conversations yet")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        } detail: {
            Group {
                if !query.isEmpty {
                    SearchResults(query: query)
                } else if let path = selection ?? projects.first?.path, let project = projects.first(where: { $0.path == path }) {
                    ProjectDetail(project: project)
                } else {
                    VStack(spacing: 10) {
                        FlickView(mood: .sleep, size: 80)
                        Text("Pick a project").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Ember.window)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search conversations")
        .toolbar {
            ToolbarItem {
                Button { index.refresh(accounts: state.config.accounts) } label: {
                    if index.isIndexing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Read the history again")
            }
        }
        .navigationTitle("Projects")
        .tint(Ember.accent)
        .modifier(FlickThemed())
        .onAppear { index.refresh(accounts: state.config.accounts) }
    }
}

private struct MiniTag: View {
    @EnvironmentObject var state: AppState
    let accountID: String
    var body: some View {
        Text(state.config.account(accountID)?.name ?? accountID)
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(state.config.color(for: accountID)))
            .fixedSize()
    }
}

/// The account a new session in this folder should use: folder rule, else the last one used there, else the active one.
@MainActor
private func accountFor(_ project: ProjectSummary, _ state: AppState) -> Account {
    state.config.ruleAccount(for: project.path)
        ?? project.accountIDs.first.flatMap { state.config.account($0) }
        ?? state.activeAccount
}

private struct ProjectDetail: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var index = HistoryIndex.shared
    let project: ProjectSummary

    var body: some View {
        let account = accountFor(project, state)
        let conversations = index.conversations.filter { $0.project == project.path }
        let cost = state.config.accounts.reduce(0.0) { sum, a in
            sum + (state.usage[a.id]?.entries.filter { e in conversations.contains { $0.id == e.session } }.reduce(0) { $0 + $1.cost } ?? 0)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(state.config.color(for: account.id))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name).font(.system(size: 22, weight: .bold))
                        Text(project.path.replacingOccurrences(of: Paths.home, with: "~"))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text("\(conversations.count) conversation\(conversations.count == 1 ? "" : "s") · \(Fmt.usd(cost)) in the last \(UsageScanner.lookbackDays) days")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button {
                        TerminalLauncher.launch(in: project.path, account: account, arguments: [], name: "new-session")
                    } label: { Label("New Session on \(account.name)", systemImage: "terminal") }
                        .buttonStyle(.borderedProminent)
                    Button { openInEditor(project.path) } label: { Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) } label: { Label("Finder", systemImage: "folder") }
                }

                VStack(spacing: 8) {
                    ForEach(conversations) { ConversationRow(conversation: $0) }
                }
            }
            .padding(24)
        }
    }

    private func openInEditor(_ path: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct ConversationRow: View {
    @EnvironmentObject var state: AppState
    let conversation: Conversation
    var showProject = false
    var snippet: String? = nil

    var body: some View {
        let c = conversation
        let account = state.config.account(c.accountID) ?? state.activeAccount
        let cost = state.usage[c.accountID]?.costBySession()[c.id]
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(c.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                if let snippet {
                    Text(snippet).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    MiniTag(accountID: c.accountID)
                    if showProject { Text(c.projectName).font(.system(size: 11, weight: .medium)) ; Text("·").foregroundStyle(.tertiary) }
                    Text(c.lastDate.formatted(date: .abbreviated, time: .shortened))
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(c.messageCount) message\(c.messageCount == 1 ? "" : "s")")
                    if let cost { Text("·").foregroundStyle(.tertiary); Text(Fmt.usd(cost)) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Resume") {
                TerminalLauncher.launch(in: c.project, account: account, arguments: ["--resume", c.id], name: "resume")
            }
            .buttonStyle(EmberButtonStyle())
            .help("Continue this conversation in Terminal, on \(account.name)")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ember.cardRaised))
        .contextMenu {
            Button("Resume in Terminal") {
                TerminalLauncher.launch(in: c.project, account: account, arguments: ["--resume", c.id], name: "resume")
            }
            Button("Open in VS Code (Claude panel)") {
                if let url = URL(string: "vscode://anthropic.claude-code/open?session=\(c.id)") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.id, forType: .string)
            }
            Button("Show Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.file]) }
        }
    }
}

private struct SearchResults: View {
    @ObservedObject private var index = HistoryIndex.shared
    let query: String

    var body: some View {
        let results = index.search(query)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(results.isEmpty ? "No conversation mentions “\(query)”" : "\(results.count) conversation\(results.count == 1 ? "" : "s") mention “\(query)”")
                    .font(.headline).padding(.bottom, 4)
                ForEach(results) { c in
                    ConversationRow(conversation: c, showProject: true, snippet: snippet(c))
                }
            }
            .padding(24)
        }
    }

    /// A few words around the first match.
    private func snippet(_ c: Conversation) -> String? {
        guard let word = query.lowercased().split(separator: " ").first.map(String.init),
              let r = c.searchText.range(of: word) else { return nil }
        let start = c.searchText.index(r.lowerBound, offsetBy: -60, limitedBy: c.searchText.startIndex) ?? c.searchText.startIndex
        let end = c.searchText.index(r.upperBound, offsetBy: 90, limitedBy: c.searchText.endIndex) ?? c.searchText.endIndex
        return "…" + c.searchText[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) + "…"
    }
}
