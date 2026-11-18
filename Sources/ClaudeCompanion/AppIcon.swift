import AppKit
import SwiftUI

/// App icon A · Ember: a warm squircle with the chat bubble and a notification badge.
/// Drawn on Apple's 1024 grid (824 pt body, centered, with a soft shadow).
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xF2935C), Color(hex: 0xD9653B), Color(hex: 0xB84A2A)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: Color(hex: 0x7A2E14).opacity(0.35), radius: 24, y: 12)

            Canvas { ctx, _ in
                // Bubble, from the 56-unit glyph, scaled ×8 and centered.
                ctx.translateBy(x: 512 - 27 * 8, y: 512 - 26 * 8)
                ctx.scaleBy(x: 8, y: 8)
                var bubble = Path()
                bubble.move(to: CGPoint(x: 10, y: 14))
                bubble.addCurve(to: CGPoint(x: 16, y: 8), control1: CGPoint(x: 10, y: 10.7), control2: CGPoint(x: 12.7, y: 8))
                bubble.addLine(to: CGPoint(x: 38, y: 8))
                bubble.addCurve(to: CGPoint(x: 44, y: 14), control1: CGPoint(x: 41.3, y: 8), control2: CGPoint(x: 44, y: 10.7))
                bubble.addLine(to: CGPoint(x: 44, y: 30))
                bubble.addCurve(to: CGPoint(x: 38, y: 36), control1: CGPoint(x: 44, y: 33.3), control2: CGPoint(x: 41.3, y: 36))
                bubble.addLine(to: CGPoint(x: 24, y: 36))
                bubble.addLine(to: CGPoint(x: 15, y: 44))
                bubble.addLine(to: CGPoint(x: 15, y: 36))
                bubble.addLine(to: CGPoint(x: 16, y: 36))
                bubble.addCurve(to: CGPoint(x: 10, y: 30), control1: CGPoint(x: 12.7, y: 36), control2: CGPoint(x: 10, y: 33.3))
                bubble.closeSubpath()
                ctx.fill(bubble, with: .color(Color(hex: 0xFFF8F2)))
                for x in [20.0, 27, 34] {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 2.6, y: 22 - 2.6, width: 5.2, height: 5.2)), with: .color(Color(hex: 0xD9653B)))
                }
                let badge = Path(ellipseIn: CGRect(x: 35, y: 4, width: 14, height: 14))
                ctx.fill(badge, with: .color(Color(hex: 0xFFD27A)))
                ctx.stroke(badge, with: .color(Color(hex: 0xD9653B)), lineWidth: 3)
            }
            .frame(width: 1024, height: 1024)
        }
        .frame(width: 1024, height: 1024)
    }

    /// `ClaudeCompanion render-icon <dir.iconset>` — writes every size macOS needs; build.sh turns it into AppIcon.icns.
    @MainActor
    static func renderIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = 1
        guard let master = renderer.cgImage else { print("render failed"); return }
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current?.imageInterpolation = .high
                NSImage(cgImage: master, size: NSSize(width: 1024, height: 1024))
                    .draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
            }
        }
    }
}
