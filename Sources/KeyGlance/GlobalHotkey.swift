import AppKit
import Carbon

/// A key + modifiers combo, persisted as two ints.
struct KeyCombo: Equatable {
    let keyCode: Int
    let modifiers: Modifiers

    func display(_ layout: KeyLayoutMap) -> String {
        let label = layout.label(for: keyCode)
        return modifiers.symbolString + (label.count == 1 ? label.uppercased() : label)
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

/// System-wide hotkey via Carbon's RegisterEventHotKey: works without Accessibility trust and
/// swallows the keystroke so it never reaches the frontmost app.
final class GlobalHotkey {
    var onPress: () -> Void = {}

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotkey.onPress() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// Registers `combo`, replacing any previous one. nil unregisters. Returns false if the OS refused
    /// (usually because another app already owns that combo).
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let combo else { return true }
        let id = EventHotKeyID(signature: OSType(0x4B47_4C4E), id: 1) // 'KGLN'
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }
}

/// Modal "press a shortcut" prompt. Returns the combo, or nil if cancelled.
enum HotkeyRecorder {
    static func record(layout: KeyLayoutMap) -> KeyCombo? {
        let alert = NSAlert()
        alert.messageText = "Press a Shortcut"
        alert.informativeText = "Opens the cheat sheet already pinned. Include ⌘, ⌥ or ⌃ (or use an F-key).\nPress esc to cancel."
        alert.addButton(withTitle: "Cancel")

        var result: KeyCombo?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = Modifiers(event.modifierFlags)
            let code = Int(event.keyCode)
            if code == 53 && mods.isEmpty { NSApp.abortModal(); return nil } // esc
            let isFKey = KeyboardGeometry.fKeyCodes.contains(code) || [105, 107, 113].contains(code)
            guard isFKey || !mods.subtracting(.shift).isEmpty else { NSSound.beep(); return nil }
            result = KeyCombo(keyCode: code, modifiers: mods)
            NSApp.stopModal()
            return nil
        }
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        previous?.activate()
        return result
    }
}
