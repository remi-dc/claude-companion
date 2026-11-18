import AppKit
import SwiftUI

/// Flick's mood, derived from what Claude is doing across your sessions.
enum FlickMood: String, CaseIterable {
    case idle, working, needs, done, sleep

    /// Slow moods need few frames; the flicker of "working" needs more.
    var framesPerSecond: Double {
        switch self {
        case .idle, .sleep: return 12
        case .needs, .done: return 20
        case .working: return 24
        }
    }

    var label: String {
        switch self {
        case .idle: return "idle"
        case .working: return "working"
        case .needs: return "needs you"
        case .done: return "done"
        case .sleep: return "sleeping"
        }
    }
}

/// Flick, the little ember. Drawn in a 120×110 space and animated from the clock,
/// so every state loops smoothly. Respects Reduce Motion.
struct FlickView: View {
    var mood: FlickMood
    var size: CGFloat = 64
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Only animate while the hosting window is actually on screen (closed popovers and windows cost nothing).
    @State private var onScreen = false

    var body: some View {
        let still = !animated || reduceMotion || !onScreen
        let view = TimelineView(.animation(minimumInterval: 1.0 / mood.framesPerSecond, paused: still)) { timeline in
            Canvas { ctx, canvasSize in
                FlickRenderer.draw(&ctx, size: canvasSize, mood: mood,
                                   t: still ? 1.0 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: size, height: size * 110 / 120)
        .accessibilityElement()
        .accessibilityLabel("Flick, \(mood.label)")
        if animated {
            view.background(WindowVisibilityReader(visible: $onScreen))
        } else {
            view
        }
    }
}

/// Reports whether the view's window is visible on screen, using AppKit's occlusion state.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = { isVisible in
            DispatchQueue.main.async { if visible != isVisible { visible = isVisible } }
        }
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { onChange?(false); return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    self?.report(closing: note.name == NSWindow.willCloseNotification)
                })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard let window, !closing else { onChange?(false); return }
            onChange?(window.isVisible && window.occlusionState.contains(.visible))
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

enum FlickRenderer {
    static let ink = Color(hex: 0x3B1A10)

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, mood: FlickMood, t: Double) {
        ctx.scaleBy(x: size.width / 120, y: size.height / 110)

        // Motion parameters per mood.
        var bob = 0.0, sway = 0.0, stretch = 1.0, blink = false
        switch mood {
        case .idle:
            stretch = 1 + 0.025 * sin(t * 2.2)
            sway = 1.5 * sin(t * 1.3)
            blink = fmod(t, 4.2) < 0.13
        case .working:
            sway = 3.5 * sin(t * 7) + 1.8 * sin(t * 11.3)
            stretch = 1 + 0.05 * sin(t * 9)
            blink = fmod(t, 3.1) < 0.1
        case .needs:
            let ph = fmod(t, 2.4)
            bob = ph < 0.8 ? -abs(sin(ph / 0.8 * .pi * 2)) * 6 : 0
            sway = 1.2 * sin(t * 3)
        case .done:
            let ph = fmod(t, 3.2)
            bob = ph < 0.55 ? -sin(ph / 0.55 * .pi) * 9 : 0
            stretch = ph < 0.55 ? 1.04 : 1 + 0.02 * sin(t * 2)
        case .sleep:
            stretch = 1 + 0.03 * sin(t * 1.1)
        }

        // Ground shadow stays put while Flick hops.
        let shadowScale = 1 + bob / 30
        ctx.fill(Path(ellipseIn: CGRect(x: 60 - 26 * shadowScale, y: 101, width: 52 * shadowScale, height: 6)),
                 with: .color(.black.opacity(0.10)))

        ctx.translateBy(x: 0, y: bob)

        // Maps a point of the resting flame to its animated position: taller parts sway more.
        func m(_ x: Double, _ y: Double) -> CGPoint {
            let h = (98 - y) / 86
            return CGPoint(x: x + sway * h * h, y: 98 - (98 - y) * stretch)
        }

        var body = Path()
        body.move(to: m(60, 12))
        body.addCurve(to: m(92, 66), control1: m(72, 28), control2: m(92, 40))
        body.addCurve(to: m(60, 98), control1: m(92, 83.7), control2: m(77.7, 98))
        body.addCurve(to: m(28, 66), control1: m(42.3, 98), control2: m(28, 83.7))
        body.addCurve(to: m(42, 35), control1: m(28, 52), control2: m(36, 42))
        body.addCurve(to: m(53, 48), control1: m(44, 43), control2: m(48, 48))
        body.addCurve(to: m(60, 12), control1: m(50, 36), control2: m(53, 23))
        body.closeSubpath()

        let top = m(60, 12), bottom = m(60, 98)
        ctx.fill(body, with: .linearGradient(
            Gradient(colors: [Color(hex: 0xF6A75E), Color(hex: 0xEB8048), Color(hex: 0xDA6A3E)]),
            startPoint: top, endPoint: bottom))

        // Warm inner glow and a soft highlight.
        let glowCenter = m(60, 80)
        ctx.fill(Path(ellipseIn: CGRect(x: glowCenter.x - 20, y: glowCenter.y - 13, width: 40, height: 26)),
                 with: .color(Color(hex: 0xFFC58F).opacity(0.35)))
        let shine = m(45, 64)
        ctx.fill(Path(ellipseIn: CGRect(x: shine.x - 4, y: shine.y - 8, width: 8, height: 16)),
                 with: .color(.white.opacity(0.3)))

        // Face.
        var face = ctx
        let fc = m(60, 74)
        face.translateBy(x: fc.x, y: fc.y)
        drawFace(&face, mood: mood, blink: blink)

        // Extras, top right.
        drawExtras(&ctx, mood: mood, t: t)
    }

    private static func drawFace(_ ctx: inout GraphicsContext, mood: FlickMood, blink: Bool) {
        let cheek = Color(hex: 0xF59A80).opacity(0.6)
        ctx.fill(Path(ellipseIn: CGRect(x: -19.5, y: 2.5, width: 7, height: 7)), with: .color(cheek))
        ctx.fill(Path(ellipseIn: CGRect(x: 12.5, y: 2.5, width: 7, height: 7)), with: .color(cheek))

        let stroke = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        func ovalEyes(dx: Double, dy: Double, rx: Double, ry: Double) {
            for cx in [-9.0, 9.0] {
                ctx.fill(Path(ellipseIn: CGRect(x: cx + dx - rx, y: dy - 1 - ry, width: rx * 2, height: ry * 2)), with: .color(ink))
            }
        }
        func arcEyes(up: Bool) {
            var p = Path()
            for (a, b) in [(-13.0, -6.0), (6.0, 13.0)] {
                p.move(to: CGPoint(x: a, y: up ? 0 : -1))
                p.addQuadCurve(to: CGPoint(x: b, y: up ? 0 : -1), control: CGPoint(x: (a + b) / 2, y: up ? -5 : 2))
            }
            ctx.stroke(p, with: .color(ink), style: stroke)
        }

        // Eyes.
        if blink || mood == .sleep {
            arcEyes(up: false)
        } else {
            switch mood {
            case .idle: ovalEyes(dx: 0, dy: 0, rx: 3, ry: 4)
            case .working: ovalEyes(dx: 2, dy: -1, rx: 3, ry: 4)
            case .needs: ovalEyes(dx: 0, dy: 0, rx: 4, ry: 5)
            case .done: arcEyes(up: true)
            case .sleep: break
            }
        }

        // Mouth.
        var mouth = Path()
        switch mood {
        case .idle:
            mouth.move(to: CGPoint(x: -4, y: 7)); mouth.addQuadCurve(to: CGPoint(x: 4, y: 7), control: CGPoint(x: 0, y: 10.5))
            ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        case .working:
            mouth.move(to: CGPoint(x: -3, y: 8)); mouth.addLine(to: CGPoint(x: 3, y: 8))
            ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        case .needs:
            ctx.fill(Path(ellipseIn: CGRect(x: -2.2, y: 5.9, width: 4.4, height: 5.2)), with: .color(ink))
        case .done:
            mouth.move(to: CGPoint(x: -6, y: 6)); mouth.addQuadCurve(to: CGPoint(x: 6, y: 6), control: CGPoint(x: 0, y: 13))
            mouth.closeSubpath()
            ctx.fill(mouth, with: .color(ink))
        case .sleep:
            mouth.move(to: CGPoint(x: -2, y: 8)); mouth.addLine(to: CGPoint(x: 2, y: 8))
            ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
    }

    private static func drawExtras(_ ctx: inout GraphicsContext, mood: FlickMood, t: Double) {
        switch mood {
        case .idle:
            break
        case .working:
            // Three dots bouncing in sequence.
            for i in 0..<3 {
                let y = 24 - abs(sin(t * 6 - Double(i) * 0.6)) * 5
                ctx.fill(Path(ellipseIn: CGRect(x: 96 + Double(i) * 8 - 2.4, y: y - 2.4, width: 4.8, height: 4.8)),
                         with: .color(Color(hex: 0xC4552E)))
            }
        case .needs:
            let s = 1 + 0.08 * sin(t * 6)
            let r = 8 * s
            ctx.fill(Path(ellipseIn: CGRect(x: 106 - r, y: 26 - r, width: r * 2, height: r * 2)), with: .color(Color(hex: 0xEB6834)))
            ctx.draw(Text("!").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundColor(.white),
                     at: CGPoint(x: 106, y: 26))
        case .done:
            let s = 0.8 + 0.3 * abs(sin(t * 3))
            var star = Path()
            let pts: [(Double, Double)] = [(0, -9), (2, -2), (9, 0), (2, 2), (0, 9), (-2, 2), (-9, 0), (-2, -2)]
            for (i, p) in pts.enumerated() {
                let pt = CGPoint(x: 104 + p.0 * s, y: 22 + p.1 * s)
                if i == 0 { star.move(to: pt) } else { star.addLine(to: pt) }
            }
            star.closeSubpath()
            ctx.fill(star, with: .color(Color(hex: 0xF5B841)))
        case .sleep:
            for i in 0..<2 {
                let ph = fmod(t * 0.45 + Double(i) * 0.5, 1)
                var z = ctx
                z.opacity = sin(ph * .pi)
                z.draw(Text("z").font(.system(size: 9 + ph * 7, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: 0x8E6A5C)),
                       at: CGPoint(x: 96 + ph * 10, y: 38 - ph * 22))
            }
        }
    }
}
