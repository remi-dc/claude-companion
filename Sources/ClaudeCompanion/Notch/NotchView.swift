import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The black island: grows out of the notch, only as big as the moment needs.
struct NotchRootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var shelf: ShelfStore

    var body: some View {
        let layout = NotchLayout.compute(model, state)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: layout.radius, bottomTrailingRadius: layout.radius, style: .continuous)
                    .fill(Color.black)
                content(layout)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            .frame(width: layout.width, height: layout.height)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: layout.radius, bottomTrailingRadius: layout.radius, style: .continuous))
            .shadow(color: .black.opacity(layout.kind == .idle ? 0 : 0.35), radius: 16, y: 8)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in shelf.add([url]) } }
                    }
                }
                return true
            }
            Spacer(minLength: 0)
        }
        .frame(width: 860, height: 440, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: layout)
    }

    @ViewBuilder
    private func content(_ layout: NotchLayout) -> some View {
        switch layout.kind {
        case .idle: IdleContent()
        case .working(let activity): WorkingContent(showActivity: activity)
        case .alert: AlertContent()
        case .expanded: ExpandedContent()
        }
    }
}

// MARK: Compact states

private struct IdleContent: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var model: NotchModel
    var body: some View {
        HStack(spacing: 0) {
            FlickView(mood: state.mood == .needs ? .needs : (state.mood == .sleep ? .sleep : .idle), size: 20, animated: false)
                .padding(.leading, 10)
            Spacer(minLength: 0)
            Circle().fill(state.config.color(for: state.activeAccount.id)).frame(width: 8, height: 8)
                .padding(.trailing, 13)
                .help(state.activeAccount.name)
        }
        .frame(height: model.geometry.hasNotch ? model.geometry.height : model.geometry.height - 4)
    }
}

private struct WorkingContent: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var model: NotchModel
    let showActivity: Bool

    var body: some View {
        let session = state.focusSession
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FlickView(mood: .working, size: 22)
                Text(model.isPrivate ? "Working" : (session?.project ?? "Working"))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: model.geometry.hasNotch ? model.geometry.notchWidth : 16)
                if let s = session {
                    Text(s.startedAt, style: .timer).font(.number(12, weight: .semibold)).monospacedDigit()
                }
                Circle().fill(state.config.color(for: session?.accountID ?? state.activeAccount.id)).frame(width: 8, height: 8)
            }
            .padding(.horizontal, 12)
            .frame(height: model.geometry.height)
            if showActivity, let activity = session?.activity {
                Text(activity)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 16).padding(.bottom, 6)
                    .id(activity)
                    .transition(.opacity)
            }
        }
    }
}

private struct AlertContent: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var model: NotchModel

    var body: some View {
        if let alert = model.alert {
            let priv = model.isPrivate
            VStack(spacing: 0) {
                Spacer().frame(height: model.geometry.height)
                HStack(spacing: 14) {
                    FlickView(mood: alert.mood, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(priv ? genericTitle(alert.mood) : alert.title)
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if !priv {
                            Text(alert.subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            if let body = alert.body, !body.isEmpty {
                                Text(body).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        ForEach(Array(alert.actions.enumerated()), id: \.offset) { _, action in
                            Button(action.0) { action.1(); model.dismiss(alert.id) }.buttonStyle(NotchPill())
                        }
                        if let text = alert.copyText, !priv {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(NotchPill())
                            .help("Copy Claude's reply")
                        }
                        if let location = alert.location, location.appBundleID != nil {
                            Button("Open") { Navigator.go(to: location); model.dismiss(alert.id) }
                                .buttonStyle(NotchPill(prominent: true))
                                .help("Go to this session")
                        }
                        Button { model.dismiss(alert.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                            .buttonStyle(NotchPill(round: true))
                            .accessibilityLabel("Dismiss")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
    }

    private func genericTitle(_ mood: FlickMood) -> String {
        switch mood {
        case .needs: return "Claude needs you"
        case .done: return "Claude is done"
        default: return "Claude Companion"
        }
    }
}

// MARK: Expanded

private struct ExpandedContent: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var music: MusicController
    @EnvironmentObject var calendar: CalendarProvider

    private var tabs: [NotchTab] {
        let n = state.config.notch
        return NotchTab.allCases.filter {
            switch $0 {
            case .claude: return true
            case .music: return n.musicTab
            case .calendar: return n.calendarTab
            case .shelf: return n.shelfTab
            case .clipboard: return n.clipboardTab
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: max(0, model.geometry.height - 6))
            HStack(spacing: 6) {
                ForEach(tabs) { t in
                    let selected = model.tab == t
                    Button { withAnimation(.spring(response: 0.3)) { model.tab = t } } label: {
                        Label(t.title, systemImage: t.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.08)))
                            .foregroundStyle(selected ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { WindowManager.shared.show("dashboard", state: state) } label: { Image(systemName: "chart.bar.xaxis") }
                    .buttonStyle(NotchPill(round: true)).help("Dashboard")
                Button { WindowManager.shared.show("settings", state: state) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(NotchPill(round: true)).help("Settings")
            }
            Group {
                switch model.tab {
                case .claude: ClaudeTab()
                case .music: MusicTab()
                case .calendar: CalendarTab()
                case .shelf: ShelfTab()
                case .clipboard: ClipboardTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .onAppear { if !tabs.contains(model.tab) { model.tab = .claude }; syncTools() }
        .onChange(of: model.tab) { syncTools() }
        .onDisappear { music.setVisible(false) }
    }

    private func syncTools() {
        music.setVisible(model.tab == .music)
        if model.tab == .calendar { calendar.load() }
    }
}

private struct ClaudeTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var model: NotchModel

    var body: some View {
        let usage = state.usage[state.activeAccount.id] ?? .empty
        let block = usage.currentBlock
        let line = state.statusLine
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                let _ = state.statusTick
                let missing = Demo.isOn ? [] : state.config.accounts.filter { !Integration.hooksUpToDate(for: $0) }
                if !missing.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.slash.fill").foregroundStyle(Ember.ring)
                        Text(missing.contains { Integration.hooksInstalled(for: $0) } ? "Hooks need an update" : "Hooks not installed")
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Button(missing.contains { Integration.hooksInstalled(for: $0) } ? "Update" : "Install") { state.installAllHooks() }
                            .buttonStyle(NotchPill(prominent: true))
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0xEB6834).opacity(0.2)))
                }
                HStack(spacing: 10) {
                    FlickView(mood: state.mood, size: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(model.isPrivate ? " " : line.subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 6) {
                        ForEach(state.config.accounts) { a in
                            let active = a.id == state.config.activeAccountID
                            Button { withAnimation(.spring(response: 0.3)) { state.activate(a.id) } } label: {
                                Text(a.name).font(.system(size: 12, weight: active ? .semibold : .regular))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(active ? state.config.color(for: a.id) : Color.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(width: 230, alignment: .leading)

            VStack(spacing: 4) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: block.map { min(1, Date().timeIntervalSince($0.start) / (5 * 3600)) } ?? 0)
                        .stroke(Ember.ring, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(Fmt.usd(block?.cost ?? 0)).font(.number(15))
                        Text(block.map { Fmt.remaining(until: $0.end) + " left" } ?? "no window")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 92, height: 92)
                Text("5-hour window").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.06)))

            VStack(spacing: 8) {
                let sessions = Array(state.sessions.values.sorted { a, b in
                    let la = a.mood == .needs || a.mood == .working, lb = b.mood == .needs || b.mood == .working
                    return la != lb ? la : a.date > b.date
                }.prefix(3))
                if sessions.isEmpty {
                    Text("No sessions yet").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(sessions) { s in
                    HStack(spacing: 10) {
                        Circle().fill(s.mood == .needs ? Color(hex: 0xEB6834) : state.config.color(for: s.accountID)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.isPrivate ? (state.config.account(s.accountID)?.name ?? "Session") : s.project)
                                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(detail(s)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if s.mood == .working {
                            Text(s.startedAt, style: .timer).font(.number(12, weight: .semibold)).monospacedDigit()
                        }
                        if s.location.appBundleID != nil {
                            Button("Open") { Navigator.go(to: s.location) }.buttonStyle(NotchPill(prominent: s.mood == .needs))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(s.mood == .needs ? Color(hex: 0xEB6834).opacity(0.22) : Color.white.opacity(0.06)))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func detail(_ s: SessionStatus) -> String {
        let account = state.config.account(s.accountID)?.name ?? s.accountID
        switch s.mood {
        case .needs: return "\(account) · needs your permission"
        case .working: return "\(account) · " + (model.isPrivate ? "working" : (s.activity ?? "working"))
        default: return "\(account) · finished \(s.date.formatted(.relative(presentation: .named)))"
        }
    }
}

private struct MusicTab: View {
    @EnvironmentObject var music: MusicController

    var body: some View {
        if let t = music.track {
            HStack(spacing: 18) {
                Group {
                    if let url = t.artworkURL {
                        AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { artworkPlaceholder }
                    } else {
                        artworkPlaceholder
                    }
                }
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    Text(t.artist).font(.system(size: 14)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Text(t.app).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    HStack(spacing: 26) {
                        Button { music.command("previous track") } label: { Image(systemName: "backward.fill") }
                        Button { music.command("playpause") } label: {
                            Image(systemName: t.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26))
                        }
                        Button { music.command("next track") } label: { Image(systemName: "forward.fill") }
                    }
                    .font(.system(size: 18))
                    .buttonStyle(.plain)
                    .padding(.top, 12)
                }
                Spacer()
            }
        } else {
            EmptyNotchState(symbol: "music.note", text: "Nothing playing in Music or Spotify")
        }
    }

    private var artworkPlaceholder: some View {
        LinearGradient(colors: [Color(hex: 0x6250D6), Color(hex: 0xE87BA4)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "music.note").font(.system(size: 40)).foregroundStyle(.white.opacity(0.8)))
    }
}

private struct CalendarTab: View {
    @EnvironmentObject var calendar: CalendarProvider

    var body: some View {
        switch calendar.access {
        case .fullAccess:
            if calendar.events.isEmpty {
                EmptyNotchState(symbol: "calendar", text: "Nothing in the next 24 hours")
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(calendar.events.enumerated()), id: \.element.id) { i, e in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(countdown(e)).font(.system(size: 12, weight: .semibold)).foregroundStyle(i == 0 ? Ember.ring : .white.opacity(0.6))
                            Text(e.title).font(.system(size: i == 0 ? 17 : 14, weight: .semibold)).lineLimit(2)
                            Text("\(e.start.formatted(date: .omitted, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                            if let url = e.joinURL {
                                Button("Join call") { NSWorkspace.shared.open(url) }
                                    .buttonStyle(NotchPill(prominent: i == 0)).padding(.top, 6)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(i == 0 ? 0.1 : 0.05)))
                    }
                }
            }
        case .notDetermined:
            VStack(spacing: 10) {
                Image(systemName: "calendar").font(.system(size: 28)).foregroundStyle(.white.opacity(0.6))
                Text("See your next meeting here").font(.system(size: 13))
                Button("Allow Calendar Access") { calendar.requestAccess() }.buttonStyle(NotchPill(prominent: true))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            EmptyNotchState(symbol: "calendar.badge.exclamationmark",
                            text: "Calendar access is off. Turn it on in System Settings › Privacy & Security › Calendars.")
        }
    }

    private func countdown(_ e: CalendarProvider.Event) -> String {
        let minutes = Int(e.start.timeIntervalSinceNow / 60)
        if minutes <= 0 { return "Now" }
        if minutes < 60 { return "In \(minutes) min" }
        return e.start.formatted(.relative(presentation: .named)).capitalized
    }
}

private struct ShelfTab: View {
    @EnvironmentObject var shelf: ShelfStore
    @EnvironmentObject var model: NotchModel

    var body: some View {
        if model.isPrivate {
            EmptyNotchState(symbol: "eye.slash", text: "Hidden while your screen is mirrored")
        } else if shelf.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 30)).foregroundStyle(.white.opacity(0.6))
                Text("Drop files on the notch to keep them here").font(.system(size: 13))
                Text("Then drag them back out anywhere: Finder, mail, Claude.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundStyle(.white.opacity(0.25)))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items, id: \.self) { url in
                            VStack(spacing: 6) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 56, height: 56)
                                Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .frame(width: 96, height: 120)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
                            .overlay(alignment: .topTrailing) {
                                Button { shelf.remove(url) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6)) }
                                    .buttonStyle(.plain).padding(4)
                            }
                            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                            .help("Drag out, or double-click to open")
                        }
                    }
                }
                HStack {
                    Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s") · drag them out, double-click to open")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button("Clear") { shelf.clear() }.buttonStyle(NotchPill())
                }
            }
        }
    }
}

private struct ClipboardTab: View {
    @EnvironmentObject var clipboard: ClipboardWatcher
    @EnvironmentObject var model: NotchModel

    var body: some View {
        if model.isPrivate {
            EmptyNotchState(symbol: "eye.slash", text: "Hidden while your screen is mirrored")
        } else if clipboard.clips.isEmpty {
            EmptyNotchState(symbol: "doc.on.clipboard", text: "Things you copy show up here. Passwords are never kept.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(clipboard.clips) { clip in
                            Button { clipboard.copy(clip) } label: {
                                HStack {
                                    Text(clip.text.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 12, design: looksLikeCode(clip.text) ? .monospaced : .default))
                                        .lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 8)
                                    Text(clip.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Copy again")
                        }
                    }
                }
                HStack {
                    Text("Click to copy again · kept in memory only").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button("Clear") { clipboard.clear() }.buttonStyle(NotchPill())
                }
            }
        }
    }

    private func looksLikeCode(_ s: String) -> Bool {
        s.hasPrefix("http") || s.hasPrefix("#") || s.contains("/") || s.contains("$ ") || s.contains("()") || s.contains(" --")
    }
}

// MARK: Pieces

private struct EmptyNotchState: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.white.opacity(0.5))
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NotchPill: ButtonStyle {
    var prominent = false
    var round = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, round ? 0 : 12)
            .padding(.vertical, round ? 0 : 6)
            .frame(width: round ? 26 : nil, height: round ? 26 : nil)
            .background(
                Group {
                    if round { Circle().fill(Color.white.opacity(0.12)) }
                    else { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(prominent ? Ember.ring : Color.white.opacity(0.12)) }
                }
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
