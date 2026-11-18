import AppKit

/// Where a Claude session lives, so a click can take you straight there.
struct SessionLocation: Codable, Hashable {
    var appBundleID: String?
    var cwd: String?
    var tty: String?
    var sessionID: String?

    var userInfo: [String: String] {
        var d: [String: String] = [:]
        d["app"] = appBundleID; d["cwd"] = cwd; d["tty"] = tty; d["session"] = sessionID
        return d
    }

    init(appBundleID: String?, cwd: String?, tty: String?, sessionID: String?) {
        self.appBundleID = appBundleID; self.cwd = cwd; self.tty = tty; self.sessionID = sessionID
    }

    init(userInfo: [AnyHashable: Any]) {
        appBundleID = userInfo["app"] as? String
        cwd = userInfo["cwd"] as? String
        tty = userInfo["tty"] as? String
        sessionID = userInfo["session"] as? String
    }
}

/// Takes you to a session: the exact Terminal/iTerm tab, or the editor window and Claude session.
enum Navigator {
    /// VS Code-family editors: URL scheme for the Claude Code extension, and their storage folder.
    private static let editors: [String: (scheme: String, support: String)] = [
        "com.microsoft.VSCode": ("vscode", "Code"),
        "com.microsoft.VSCodeInsiders": ("vscode-insiders", "Code - Insiders"),
        "com.todesktop.230313mzl4w4u92": ("cursor", "Cursor"),
        "com.exafunction.windsurf": ("windsurf", "Windsurf"),
    ]

    @MainActor
    static func go(to location: SessionLocation) {
        guard let app = location.appBundleID else { return }
        if let editor = editors[app] {
            openInEditor(app, editor: editor, location: location)
            return
        }
        if let tty = location.tty {
            let script: String?
            switch app {
            case "com.apple.Terminal": script = terminalScript(tty)
            case "com.googlecode.iterm2": script = iTermScript(tty)
            default: script = nil
            }
            if let script, run(script) { return }
        }
        activate(app)
    }

    private static func activate(_ bundleID: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
    }

    // MARK: Editors

    private static func openInEditor(_ bundleID: String, editor: (scheme: String, support: String), location: SessionLocation) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return activate(bundleID) }

        // 1. Focus the window that has this project open (opening an already-open folder focuses its window).
        if let cwd = location.cwd {
            let folder = openWorkspaceFolder(containing: cwd, support: editor.support) ?? cwd
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: appURL, configuration: config)
        } else {
            activate(bundleID)
        }

        // 2. Then ask the Claude Code extension to show that session in the now-focused window.
        if let session = location.sessionID,
           let url = URL(string: "\(editor.scheme)://anthropic.claude-code/open?session=\(session)") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// The editor's open window folder that contains `cwd` (deepest match), so a session started in a
    /// subfolder still lands in its workspace window instead of opening a new one.
    private static func openWorkspaceFolder(containing cwd: String, support: String) -> String? {
        let path = Paths.home + "/Library/Application Support/\(support)/User/globalStorage/storage.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["windowsState"] as? [String: Any] else { return nil }
        var windows = (state["openedWindows"] as? [[String: Any]]) ?? []
        if let last = state["lastActiveWindow"] as? [String: Any] { windows.append(last) }
        let folders = windows.compactMap { ($0["folder"] as? String).flatMap(URL.init(string:))?.path }
        return folders
            .filter { cwd == $0 || cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }

    // MARK: Terminals (AppleScript; macOS asks once for permission)

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func terminalScript(_ tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escape(tty))" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    private static func iTermScript(_ tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escape(tty))" then
                            select w
                            tell t to select
                            tell s to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }

    private static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Claude Companion: AppleScript failed: %@", error) }
        return result?.booleanValue == true
    }
}
