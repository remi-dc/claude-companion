import AppKit
import Foundation

/// Checks GitHub for a newer release and installs it in one click.
/// The check is a single anonymous request to the public GitHub API: no data about you is sent.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let notes: String
        let zipURL: URL
        let pageURL: URL
    }

    enum Phase: Equatable {
        case idle, checking, downloading, installing
        case failed(String)
    }

    @Published private(set) var available: Release?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?

    nonisolated static let repo = "remi-dc/claude-companion"
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static let skippedKey = "skippedUpdateVersion"
    private let feed: URL = {
        if let s = ProcessInfo.processInfo.environment["CLAUDE_COMPANION_UPDATE_URL"], let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }()
    private var timer: Timer?

    func start() {
        Task { try? await Task.sleep(for: .seconds(5)); await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    // MARK: Checking

    /// `userInitiated` shows versions you chose to skip, and errors.
    func check(userInitiated: Bool = false) async {
        if phase == .downloading || phase == .installing { return }
        phase = .checking
        defer { if phase == .checking { phase = .idle } }
        do {
            guard let release = try await Self.fetchLatest(from: feed) else { available = nil; lastChecked = Date(); return }
            lastChecked = Date()
            let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
            if Self.isNewer(release.version, than: Self.currentVersion), userInitiated || skipped != release.version {
                available = release
                // For testing the whole update path without clicking.
                if ProcessInfo.processInfo.environment["CLAUDE_COMPANION_UPDATE_AUTOINSTALL"] != nil {
                    phase = .idle
                    await install()
                }
            } else {
                available = nil
            }
        } catch {
            if userInitiated { phase = .failed("Couldn't check for updates. Are you online?") }
        }
    }

    func skip() {
        guard let v = available?.version else { return }
        UserDefaults.standard.set(v, forKey: Self.skippedKey)
        available = nil
        phase = .idle
    }

    nonisolated static func fetchLatest(from feed: URL) async throws -> Release? {
        var request = URLRequest(url: feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeCompanion-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }   // no release yet
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String) == "ClaudeCompanion.zip" }),
              let zipString = zip["browser_download_url"] as? String, let zipURL = URL(string: zipString) else { return nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(repo)/releases")!
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: (json["body"] as? String) ?? "", zipURL: zipURL, pageURL: page)
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    /// Downloads, verifies, then swaps the app in place and relaunches it.
    func install() async {
        guard let release = available else { return }
        let dest = Bundle.main.bundlePath
        let parent = (dest as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent), dest.hasSuffix(".app") else {
            phase = .failed("Can't write to \(parent). Run the install command instead.")
            return
        }

        phase = .downloading
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCompanionUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: release.zipURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
            let zip = work.appendingPathComponent("app.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)

            phase = .installing
            let unzipped = work.appendingPathComponent("unzipped")
            guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path]) else { throw UpdateError.unzip }
            let newApp = unzipped.appendingPathComponent("Claude Companion.app")

            // Only install what is really a newer Claude Companion with an intact signature.
            guard let bundle = Bundle(url: newApp), bundle.bundleIdentifier == kBundleID,
                  (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) == release.version,
                  Self.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path]) else { throw UpdateError.verify }
            _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            // A tiny script waits for us to quit, swaps the app (restoring the old one on failure), and relaunches.
            func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = """
            #!/bin/sh
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf \(q(dest + ".old"))
            if mv \(q(dest)) \(q(dest + ".old")) && /usr/bin/ditto \(q(newApp.path)) \(q(dest)); then
              rm -rf \(q(dest + ".old"))
            else
              rm -rf \(q(dest)); mv \(q(dest + ".old")) \(q(dest))
            fi
            open \(q(dest))
            rm -rf \(q(work.path))
            """
            let scriptURL = work.appendingPathComponent("swap.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [scriptURL.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error is UpdateError ? "The download didn't check out, so nothing was changed." : "The update couldn't be downloaded.")
        }
    }

    enum UpdateError: Error { case unzip, verify }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
