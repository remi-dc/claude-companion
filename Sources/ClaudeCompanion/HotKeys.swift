import AppKit
import Carbon.HIToolbox
import SwiftUI

/// System-wide shortcuts via Carbon's RegisterEventHotKey (no Accessibility permission needed).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    /// Replaces all registered shortcuts. Returns the action ids that couldn't be registered (taken by another app).
    @discardableResult
    func register(_ shortcuts: [String: Shortcut], perform: @escaping (String) -> Void) -> [String] {
        installHandler()
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        var failed: [String] = []
        for (index, action) in Shortcut.actions.enumerated() {
            guard let s = shortcuts[action.id] else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(s.keyCode, s.modifiers, EventHotKeyID(signature: OSType(0x4343_4D50), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = { perform(action.id) }
            } else {
                failed.append(action.id)
            }
        }
        return failed
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Opens (or closes) the menu bar popover by clicking our status item.
    static func togglePopover() {
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            if let button = findButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let b = findButton(in: sub) { return b } }
        return nil
    }

    // MARK: Converting key events

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    static func display(_ flags: NSEvent.ModifierFlags, key: String) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    static func keyName(_ event: NSEvent) -> String {
        // The digit row shows its digit on every layout (on AZERTY those keys type &, é, "…).
        let digits: [Int: String] = [kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
                                     kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_0: "0"]
        if let d = digits[Int(event.keyCode)] { return d }
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            if let fn = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                         kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"][Int(event.keyCode)] {
                return fn
            }
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// Click, then type a shortcut. Esc cancels, Delete clears (turns the shortcut off).
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? (hint ?? "Type a shortcut…") : (shortcut?.display ?? "Off"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(recording ? Ember.accent : (shortcut == nil ? .secondary : .primary))
                    .frame(minWidth: 110)
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(recording ? Ember.accent : Color.secondary.opacity(0.3), lineWidth: recording ? 1.5 : 1))
            }
            .buttonStyle(.plain)
            .help("Click, then press the keys. Esc cancels, Delete turns it off.")
            if shortcut != nil && !recording {
                Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Turn shortcut off")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                shortcut = nil; stop()
            default:
                // Require ⌘, ⌥ or ⌃ so plain typing never triggers a global shortcut.
                guard !flags.intersection([.command, .option, .control]).isEmpty else {
                    hint = "Add ⌘, ⌥ or ⌃"
                    return nil
                }
                shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: HotKeys.carbonModifiers(flags),
                                    display: HotKeys.display(flags, key: HotKeys.keyName(event)))
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
