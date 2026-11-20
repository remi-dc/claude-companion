import AppKit
import EventKit
import SwiftUI

// MARK: Music (Music and Spotify, via AppleScript; macOS asks once per app)

@MainActor
final class MusicController: ObservableObject {
    struct Track: Equatable {
        var app: String          // "Spotify" or "Music"
        var title: String
        var artist: String
        var artworkURL: URL?
        var isPlaying: Bool
        var position: Double = 0      // seconds, when fetched
        var duration: Double = 0      // seconds
        var fetchedAt = Date()

        /// Position now, moving forward while playing between polls.
        func currentPosition(at date: Date) -> Double {
            min(duration, position + (isPlaying ? date.timeIntervalSince(fetchedAt) : 0))
        }
    }

    @Published private(set) var track: Track?
    private var timer: Timer?
    var demoTrack: Track?

    /// Polls only while the Music tab is on screen.
    func setVisible(_ visible: Bool) {
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        if let demoTrack { track = demoTrack; return }
        // Never launch an app just to ask what it's playing.
        let spotify = isRunning("com.spotify.client") ? query("Spotify", artwork: true) : nil
        let music = isRunning("com.apple.Music") ? query("Music", artwork: false) : nil
        track = [spotify, music].compactMap { $0 }.first(where: \.isPlaying) ?? spotify ?? music
    }

    /// Brings the player (Spotify or Music) to the front.
    func openPlayer() {
        guard let app = track?.app else { return }
        let id = app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func command(_ verb: String) {
        guard let app = track?.app else { return }
        run("tell application \"\(app)\" to \(verb)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    private func isRunning(_ id: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    private func query(_ app: String, artwork: Bool) -> Track? {
        // Spotify reports the duration in milliseconds, Music in seconds.
        let art = artwork ? "(artwork url of current track)" : "\"\""
        let script = """
        tell application "\(app)"
            if player state is stopped then return ""
            return (player state as string) & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & \(art) & linefeed & (player position as string) & linefeed & (duration of current track as string)
        end tell
        """
        guard let out = run(script), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 3 else { return nil }
        func num(_ i: Int) -> Double { parts.count > i ? Double(parts[i].replacingOccurrences(of: ",", with: ".")) ?? 0 : 0 }
        var duration = num(5)
        if app == "Spotify" { duration /= 1000 }
        return Track(app: app, title: parts[1], artist: parts[2],
                     artworkURL: parts.count > 3 && !parts[3].isEmpty ? URL(string: parts[3]) : nil,
                     isPlaying: parts[0] == "playing", position: num(4), duration: duration, fetchedAt: Date())
    }

    @discardableResult
    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }
}

// MARK: Calendar (EventKit; macOS asks once)

@MainActor
final class CalendarProvider: ObservableObject {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let joinURL: URL?
        var calendarItemID: String? = nil

        /// Shows the event in the Calendar app.
        func open() {
            if let id = calendarItemID, let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"),
               NSWorkspace.shared.open(url) { return }
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    @Published var events: [Event] = []
    @Published var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    var demo = false
    private let store = EKEventStore()
    private var lastLoad = Date.distantPast

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.access = EKEventStore.authorizationStatus(for: .event)
                self.load(force: true)
            }
        }
    }

    func load(force: Bool = false) {
        if demo { return }
        access = EKEventStore.authorizationStatus(for: .event)
        guard access == .fullAccess, force || Date().timeIntervalSince(lastLoad) > 120 else { return }
        lastLoad = Date()
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60),
                                                 end: now.addingTimeInterval(7 * 24 * 3600), calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)
            .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Event",
                         start: $0.startDate, end: $0.endDate, joinURL: Self.joinLink($0),
                         calendarItemID: $0.calendarItemIdentifier) }
    }

    /// Meet, Zoom or Teams link from the event's URL, location or notes.
    static func joinLink(_ e: EKEvent) -> URL? {
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://(meet\.google\.com|[\w.-]*zoom\.us|teams\.microsoft\.com|teams\.live\.com)/[^\s<>"]+"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[r]))
    }
}

// MARK: Shelf (files dropped on the notch)

@MainActor
final class ShelfStore: ObservableObject {
    @Published var items: [URL] = []
    private static let key = "notchShelf"

    init() {
        items = (UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) { items.insert(url, at: 0) }
        save()
    }

    func remove(_ url: URL) { items.removeAll { $0 == url }; save() }
    func clear() { items = []; save() }

    private func save() { UserDefaults.standard.set(items.map(\.path), forKey: Self.key) }
}

// MARK: Clipboard (in memory only; never stores what apps mark as sensitive)

@MainActor
final class ClipboardWatcher: ObservableObject {
    struct Clip: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let date: Date
    }

    @Published var clips: [Clip] = []
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var ignoreChange: Int?
    private static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "com.typeit4me.clipping", "de.petermaurer.TransientPasteboardType",
    ]

    func setEnabled(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        if !on { clips = []; return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if ignoreChange == pb.changeCount { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.sensitiveTypes),
              let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        clips.removeAll { $0.text == text }
        clips.insert(Clip(text: text, date: Date()), at: 0)
        if clips.count > 15 { clips.removeLast(clips.count - 15) }
    }

    /// Puts a clip back on the clipboard (and moves it to the top).
    func copy(_ clip: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clip.text, forType: .string)
        ignoreChange = pb.changeCount
        lastChange = pb.changeCount
        clips.removeAll { $0.id == clip.id }
        clips.insert(Clip(text: clip.text, date: Date()), at: 0)
    }

    func clear() { clips = [] }
}
