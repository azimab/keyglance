import AppKit
import Carbon

/// A key + modifiers combo, persisted as two ints.
struct KeyCombo: Hashable, Codable {
    let keyCode: Int
    let modifiers: Modifiers

    func display(_ layout: KeyLayoutMap) -> String {
        let label = layout.label(for: keyCode)
        return modifiers.symbolString + (label.count == 1 ? label.uppercased() : label.prefix(1).uppercased() + label.dropFirst())
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

/// System-wide hotkeys via Carbon's RegisterEventHotKey: they work without Accessibility trust and
/// swallow the keystroke so it never reaches the frontmost app. Each registration gets its own id.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotkeyCenter.shared.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Returns a token for `unregister`, or nil if the OS refused the combo (usually because it's
    /// already registered, by KeyGlance or another app).
    func register(_ combo: KeyCombo, action: @escaping () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers,
                                         EventHotKeyID(signature: OSType(0x4B47_4C4E), id: id), // 'KGLN'
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        actions[id] = action
        return id
    }

    func unregister(_ token: UInt32?) {
        guard let token, let ref = refs.removeValue(forKey: token) else { return }
        UnregisterEventHotKey(ref)
        actions[token] = nil
    }
}

/// A single replaceable hotkey slot (the Pinned Shortcut).
final class GlobalHotkey {
    var onPress: () -> Void = {}
    private var token: UInt32?

    /// Registers `combo`, replacing any previous one. nil unregisters. Returns false if the OS refused.
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        HotkeyCenter.shared.unregister(token)
        token = nil
        guard let combo else { return true }
        token = HotkeyCenter.shared.register(combo) { [weak self] in self?.onPress() }
        return token != nil
    }
}

/// Modal "press a shortcut" prompt. Returns the combo, or nil if cancelled.
enum HotkeyRecorder {
    static func record(layout: KeyLayoutMap,
                       message: String = "Opens the cheat sheet already pinned.") -> KeyCombo? {
        let alert = NSAlert()
        alert.messageText = "Press a Shortcut"
        alert.informativeText = "\(message) Include ⌘, ⌥ or ⌃ (or use an F-key).\nPress esc to cancel."
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
