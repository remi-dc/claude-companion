import AppKit
import SwiftUI

/// "Stays on screen" notifications. macOS only lets an app pick banners *or* alerts for all of its
/// notifications, so sticky ones are our own cards in the top-right corner: they stay until you
/// click them, and go away by themselves once the session moves on (e.g. you approved the permission).
@MainActor
final class StickyNotes {
    static let shared = StickyNotes()

    struct Note {
        let id: String              // session key (or a unique id for alerts)
        let title: String
        let subtitle: String
        let body: String
        let mood: FlickMood
        let palette: FlickPalette
        let location: SessionLocation?
    }

    private var panels: [(id: String, panel: NSPanel)] = []
    private let width: CGFloat = 360
    private let maxVisible = 4

    func show(_ note: Note) {
        dismiss(note.id, animated: false)   // one card per session: replace, don't stack duplicates
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 96),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        let card = StickyCard(note: note,
                              open: { [weak self] in
                                  if let location = note.location { Navigator.go(to: location) }
                                  self?.dismiss(note.id)
                              },
                              close: { [weak self] in self?.dismiss(note.id) })
            .environment(\.flickPalette, note.palette)
        let host = NSHostingView(rootView: card)
        host.frame.size = host.fittingSize
        panel.setContentSize(NSSize(width: width, height: max(host.fittingSize.height, 80)))
        panel.contentView = host

        panels.insert((note.id, panel), at: 0)
        while panels.count > maxVisible { dismiss(panels.last!.id, animated: false) }
        layout(newest: panel)
    }

    /// Removes the card for this session, if any.
    func dismiss(_ id: String, animated: Bool = true) {
        guard let index = panels.firstIndex(where: { $0.id == id }) else { return }
        let panel = panels.remove(at: index).panel
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        } else {
            panel.orderOut(nil)
        }
        layout(newest: nil)
    }

    func dismissAll() { panels.map(\.id).forEach { dismiss($0) } }

    /// Stacks cards from the top-right corner of the main screen, newest on top.
    private func layout(newest: NSPanel?) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var y = screen.maxY - 12
        for (_, panel) in panels {
            let h = panel.frame.height
            y -= h
            let target = NSRect(x: screen.maxX - width - 12, y: y, width: width, height: h)
            if panel === newest {
                panel.setFrame(target.offsetBy(dx: 40, dy: 0), display: false)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                    panel.animator().setFrame(target, display: true)
                    panel.animator().alphaValue = 1
                }
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    panel.animator().setFrame(target, display: true)
                }
            }
            y -= 10
        }
    }
}

private struct StickyCard: View {
    let note: StickyNotes.Note
    let open: () -> Void
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FlickView(mood: note.mood, size: 46, animated: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(note.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if !note.body.isEmpty {
                    Text(note.body).font(.system(size: 12)).lineLimit(2).padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(hover ? 0.12 : 0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                if note.location?.appBundleID != nil {
                    Button("Open", action: open).buttonStyle(EmberButtonStyle())
                }
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ember.accent.opacity(0.35)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
    }
}
