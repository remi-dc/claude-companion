import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Sends notifications to your phone with ntfy (a free, open-source push service you can self-host).
/// Only what you allow is sent; by default no message text, only "School needs a hand · billing-api".
enum Phone {
    enum Kind { case permission, finished, waiting, alert }

    /// Seconds since the last keyboard or mouse input.
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static let iconURL = "https://raw.githubusercontent.com/remi-dc/claude-companion/main/docs/images/notify-icon.png"

    /// Builds a tidy notification: a short title for what happened, "Account · project" underneath,
    /// an emoji per kind (from ntfy tags), Flick's icon (Android) and a tap that opens Claude.
    @MainActor
    static func maybeSend(_ kind: Kind, title: String, account: String?, project: String?, text: String?, settings s: PhoneSettings) {
        guard s.enabled else { return }
        switch kind {
        case .permission: guard s.permission else { return }
        case .finished: guard s.finished else { return }
        case .waiting: guard s.waiting else { return }
        case .alert: guard s.alerts else { return }
        }
        let locked = screenLocked, idle = idleSeconds
        if s.onlyWhenAway, !locked, idle < Double(s.awayMinutes) * 60 {
            record("Skipped “\(title)”: you were at the Mac (idle \(Int(idle)) s, screen unlocked)")
            return
        }
        var lines = [[account, project].compactMap { $0 }.joined(separator: " · ")].filter { !$0.isEmpty }
        if s.includeText, let text, !text.isEmpty { lines.append(text) }
        let style: (tag: String, priority: Int) = {
            switch kind {
            case .permission: return ("raised_hand", 4)
            case .finished: return ("white_check_mark", 3)
            case .waiting: return ("speech_balloon", 3)
            case .alert: return ("bar_chart", 3)
            }
        }()
        send(title: title, body: lines.isEmpty ? "Claude Companion" : lines.joined(separator: "\n\n"),
             priority: style.priority, tags: style.tag, settings: s) { ok in
            record(ok ? "Sent “\(title)” (\(locked ? "screen locked" : "idle \(Int(idle)) s"))" : "Couldn't send “\(title)”: the server didn't answer")
        }
    }

    /// The last decision, shown in Settings › Phone so you can see why something was or wasn't sent.
    static func record(_ text: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) · \(text)"
        UserDefaults.standard.set(line, forKey: "phoneLastStatus")
        NSLog("Claude Companion phone: %@", text)
    }

    static var lastStatus: String? { UserDefaults.standard.string(forKey: "phoneLastStatus") }

    /// One JSON publish to the server (JSON keeps accents and "·" intact; HTTP headers don't).
    @discardableResult
    static func send(title: String, body: String, priority: Int = 3, tags: String = "fire", settings s: PhoneSettings,
                     completion: ((Bool) -> Void)? = nil) -> Bool {
        let server = s.server.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: server), url.scheme == "https" || url.scheme == "http" else { completion?(false); return false }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["topic": s.topic, "title": String(title.prefix(200)),
                                      "message": String(body.prefix(1000)), "priority": priority, "tags": [tags],
                                      "icon": iconURL]
        if s.openClaudeOnTap { payload["click"] = "https://claude.ai/code" }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, response, error in
            let ok = error == nil && ((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
            DispatchQueue.main.async { completion?(ok) }
        }.resume()
        return true
    }

    /// A QR code of the topic's address, to subscribe from the phone.
    static func qrCode(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
