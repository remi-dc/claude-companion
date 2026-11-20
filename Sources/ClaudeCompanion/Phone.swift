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

    @MainActor
    static func maybeSend(_ kind: Kind, title: String, body: String?, settings s: PhoneSettings) {
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
        send(title: title, body: (s.includeText ? body : nil) ?? "Open your Mac to see it.",
             priority: kind == .permission ? 4 : 3, tags: kind == .permission ? "raised_hand" : "fire", settings: s) { ok in
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
        let payload: [String: Any] = ["topic": s.topic, "title": String(title.prefix(200)),
                                      "message": String(body.prefix(1000)), "priority": priority, "tags": [tags]]
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
