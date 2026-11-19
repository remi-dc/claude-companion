import AppKit
import SwiftUI

/// The menu bar glyph: a monochrome chat bubble, like the system icons.
/// Working: three dots cycle. Needs you: a badge in the account's color. Paused: slashed.
enum MenuBarIcon {
    static func image(mood: FlickMood, paused: Bool, frame: Int, badge: NSColor?, accountDot: NSColor? = nil) -> NSImage {
        let size = NSSize(width: 22, height: 20)
        let colored = (badge != nil && !paused) || accountDot != nil
        let image = NSImage(size: size, flipped: true) { _ in
            let ink: NSColor = colored ? .labelColor : .black
            let bubble = NSBezierPath()
            bubble.move(to: NSPoint(x: 3, y: 5.5))
            bubble.curve(to: NSPoint(x: 5.5, y: 3), controlPoint1: NSPoint(x: 3, y: 4.1), controlPoint2: NSPoint(x: 4.1, y: 3))
            bubble.line(to: NSPoint(x: 14.5, y: 3))
            bubble.curve(to: NSPoint(x: 17, y: 5.5), controlPoint1: NSPoint(x: 15.9, y: 3), controlPoint2: NSPoint(x: 17, y: 4.1))
            bubble.line(to: NSPoint(x: 17, y: 11.5))
            bubble.curve(to: NSPoint(x: 14.5, y: 14), controlPoint1: NSPoint(x: 17, y: 12.9), controlPoint2: NSPoint(x: 15.9, y: 14))
            bubble.line(to: NSPoint(x: 9, y: 14))
            bubble.line(to: NSPoint(x: 5.5, y: 17))
            bubble.line(to: NSPoint(x: 5.5, y: 14))
            bubble.curve(to: NSPoint(x: 3, y: 11.5), controlPoint1: NSPoint(x: 4.1, y: 14), controlPoint2: NSPoint(x: 3, y: 12.9))
            bubble.close()
            bubble.lineWidth = 1.6
            bubble.lineJoinStyle = .round
            (paused ? ink.withAlphaComponent(0.55) : ink).setStroke()
            bubble.stroke()

            if paused {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3, y: 2))
                slash.line(to: NSPoint(x: 17, y: 17))
                slash.lineWidth = 1.6
                slash.lineCapStyle = .round
                ink.withAlphaComponent(0.55).setStroke()
                slash.stroke()
            } else if mood == .working {
                for i in 0..<3 {
                    ink.withAlphaComponent(i == frame % 3 ? 1 : 0.3).setFill()
                    NSBezierPath(ovalIn: NSRect(x: 5.8 + Double(i) * 3, y: 7.3, width: 2.4, height: 2.4)).fill()
                }
            }

            if let accountDot {
                // The active account's color, bottom right.
                accountDot.setFill()
                NSBezierPath(ovalIn: NSRect(x: 15.2, y: 12.6, width: 6, height: 6)).fill()
            }

            if let badge, !paused {
                let ring = NSBezierPath(ovalIn: NSRect(x: 14, y: 0.5, width: 7.4, height: 7.4))
                badge.setFill()
                ring.fill()
            }
            return true
        }
        image.isTemplate = !colored
        image.accessibilityDescription = "Claude Companion, \(paused ? "paused" : mood.label)"
        return image
    }
}
