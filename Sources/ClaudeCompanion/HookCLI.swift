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
}

/// `ClaudeCompanion hook <stop|notification> --account <id>`
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

        if kind == "notification" {
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
                              body: body, sessionID: json["session_id"] as? String)

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

    /// App not running: still show something via AppleScript, with the configured sound.
    static func fallbackNotify(_ msg: HookMessage) {
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
