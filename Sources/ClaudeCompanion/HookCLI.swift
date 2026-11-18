import AppKit
import Foundation

let kBundleID = "dev.claudecompanion.app"
let kHookNotification = Notification.Name("dev.claudecompanion.hook")

/// What a hook invocation turns into. Sent from the CLI process to the running app.
struct HookMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var accountID: String
    var event: HookEvent
    var project: String
    var body: String
    var sessionID: String?
    /// The app hosting the session (Terminal, VS Code…), so we can bring it to the front.
    var appBundleID: String?
    var cwd: String?
    var tty: String?

    var location: SessionLocation {
        SessionLocation(appBundleID: appBundleID, cwd: cwd, tty: tty, sessionID: sessionID)
    }
}

/// `ClaudeCompanion hook <stop|notification|prompt|tool> --account <id>`
/// Claude Code pipes the hook JSON on stdin. We must be quick and always exit 0.
enum HookCLI {
    static func run(_ args: [String]) {
        let kind = args.first ?? "stop"
        var accountID = "personal"
        if let i = args.firstIndex(of: "--account"), i + 1 < args.count { accountID = args[i + 1] }

        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]

        let cwd = json["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        let project = (cwd as NSString).lastPathComponent
        let event: HookEvent
        var body: String

        // "prompt": you sent a message. "tool": Claude finished an action, so it's working again
        // (e.g. right after you approved a permission or answered a question).
        if kind == "prompt" || kind == "tool" {
            event = .started
            body = ""
        } else if kind == "notification" {
            let message = json["message"] as? String ?? "Claude needs your attention"
            let type = json["notification_type"] as? String ?? ""
            if type == "permission_prompt" || message.localizedCaseInsensitiveContains("permission") {
                event = .permission
            } else {
                event = .waiting
            }
            body = message
        } else {
            event = .finished
            body = (json["transcript_path"] as? String).flatMap(lastAssistantText) ?? "Done."
        }
        if body.count > 180 { body = String(body.prefix(177)) + "…" }

        let msg = HookMessage(accountID: accountID, event: event, project: project,
                              body: body, sessionID: json["session_id"] as? String,
                              appBundleID: hostAppBundleID(), cwd: cwd, tty: controllingTTY())

        // CLAUDE_COMPANION_DEBUG=1: print what would be sent, for troubleshooting.
        if ProcessInfo.processInfo.environment["CLAUDE_COMPANION_DEBUG"] != nil,
           let data = try? JSONEncoder().encode(msg) {
            print(String(decoding: data, as: UTF8.self))
            return
        }

        if !NSRunningApplication.runningApplications(withBundleIdentifier: kBundleID).isEmpty,
           let data = try? JSONEncoder().encode(msg), let str = String(data: data, encoding: .utf8) {
            DistributedNotificationCenter.default().postNotificationName(
                kHookNotification, object: nil, userInfo: ["payload": str], deliverImmediately: true)
            // Give the distributed notification a moment to leave the process.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } else {
            fallbackNotify(msg)
        }
    }

    /// Walks up the process tree to the first regular app (Terminal, iTerm, VS Code, Cursor…).
    /// The process that ran the hook. The shim passes it along, because by the time this
    /// background process looks, the shim itself may already have exited.
    static var hookParentPID: pid_t {
        if let s = ProcessInfo.processInfo.environment["CLAUDE_COMPANION_PPID"], let p = pid_t(s), p > 1 { return p }
        return getppid()
    }

    static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// The terminal device of the Claude session (e.g. /dev/ttys003), to find its exact tab.
    static func controllingTTY() -> String? {
        var pid = hookParentPID
        for _ in 0..<30 {
            guard let info = processInfo(pid) else { return nil }
            let dev = info.kp_eproc.e_tdev
            if dev != -1, let name = devname(dev, S_IFCHR) {
                let s = String(cString: name)
                if s != "??" { return "/dev/" + s }
            }
            let parent = info.kp_eproc.e_ppid
            if parent <= 1 { return nil }
            pid = parent
        }
        return nil
    }

    static func hostAppBundleID() -> String? {
        var pid = hookParentPID
        for _ in 0..<30 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
               let id = app.bundleIdentifier, id != kBundleID {
                return id
            }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let parent = info.kp_eproc.e_ppid
            if parent <= 1 { return nil }
            pid = parent
        }
        return nil
    }

    /// App not running: still show something via AppleScript, with the configured sound.
    static func fallbackNotify(_ msg: HookMessage) {
        if msg.event == .started { return }
        let cfg = CompanionConfig.load()
        if cfg.paused { return }
        let account = cfg.account(msg.accountID)
        if account?.notificationsEnabled == false { return }
        let title = "[\(account?.name ?? msg.accountID)] \(msg.event.title) · \(msg.project)"
        let sound = account?.sound(for: msg.event) ?? "Glass"
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var script = "display notification \"\(esc(msg.body))\" with title \"\(esc(title))\""
        if sound != "None" { script += " sound name \"\(esc(sound))\"" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
        p.waitUntilExit()
    }

    /// Pull the last thing Claude said out of the transcript tail for the notification body.
    static func lastAssistantText(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tail: UInt64 = 256 * 1024
        try? fh.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return nil
    }
}
