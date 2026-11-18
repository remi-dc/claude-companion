import AppKit
import UserNotifications

enum Sounds {
    /// System sounds plus anything the user dropped into ~/Library/Sounds.
    static func available() -> [String] {
        let dirs = ["/System/Library/Sounds", Paths.home + "/Library/Sounds"]
        var names = Set<String>()
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] {
                let ext = (f as NSString).pathExtension.lowercased()
                if ["aiff", "aif", "wav", "mp3", "m4a", "caf"].contains(ext) {
                    names.insert((f as NSString).deletingPathExtension)
                }
            }
        }
        return ["None"] + names.sorted()
    }

    private static var current: NSSound?

    static func play(_ name: String) {
        guard name != "None", let s = NSSound(named: NSSound.Name(name)) else { return }
        current?.stop()
        current = s
        s.play()
    }

    /// Copies a user-picked audio file into ~/Library/Sounds and returns its sound name.
    static func importCustom(_ url: URL) -> String? {
        let dir = Paths.home + "/Library/Sounds"
        Paths.ensureDir(dir)
        let dest = URL(fileURLWithPath: dir).appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return nil }
        return url.deletingPathExtension().lastPathComponent
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Permission { case unknown, allowed, denied }

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    /// Checked live each time, so permission granted later in System Settings takes effect immediately.
    func permission(_ completion: @escaping (Permission) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let p: Permission
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: p = .allowed
            case .denied: p = .denied
            default: p = .unknown
            }
            DispatchQueue.main.async { completion(p) }
        }
    }

    func post(_ msg: HookMessage, account: Account?, preview: Bool) {
        let accountName = account?.name ?? msg.accountID
        if let account { Sounds.play(account.sound(for: msg.event)) }

        let title = "\(msg.event.title) · \(msg.project)"
        let body = preview ? msg.body : ""

        permission { p in
            guard p == .allowed else {
                // No Notification Center permission: AppleScript banner instead (sound already played).
                HookCLI.fallbackNotifySilent(title: "[\(accountName)] \(title)", body: body)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = accountName
            content.body = body
            content.threadIdentifier = msg.accountID
            content.interruptionLevel = msg.event == .permission ? .timeSensitive : .active
            let req = UNNotificationRequest(identifier: msg.id.uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { error in
                if let error { NSLog("Claude Companion: failed to post notification: %@", String(describing: error)) }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(kBundleID)")!
        NSWorkspace.shared.open(url)
    }
}

extension HookCLI {
    static func fallbackNotifySilent(title: String, body: String) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        try? p.run()
    }
}
