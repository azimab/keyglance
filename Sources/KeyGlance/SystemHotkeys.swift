import AppKit

/// A macOS system shortcut from System Settings › Keyboard › Keyboard Shortcuts.
struct SystemHotkey: Identifiable, Hashable {
    let id: Int
    let name: String
    let keyCode: Int
    let modifiers: Modifiers
    /// Held fn/🌐 on a key where fn isn't implied (e.g. fn-Q for Quick Note; not F11 or arrows).
    let fn: Bool
    let enabled: Bool

    func display(_ layout: KeyLayoutMap) -> String {
        let label = keyCode == 49 ? "Space" : layout.label(for: keyCode)
        return (fn ? "fn " : "") + modifiers.symbolString + label
    }
}

/// Reads `com.apple.symbolichotkeys`. The plist only holds entries the user (or an OS update) changed,
/// so the built-in defaults below fill in the rest. The IDs are undocumented; names and defaults are a
/// best-effort table for macOS 13+, and unknown IDs show as "System shortcut #N".
enum SystemHotkeys {
    private struct Default {
        let name: String
        var code: Int? = nil
        var mods: Modifiers = []
        var fn = false
        var enabled = true
    }

    /// Shift-variants macOS keeps alongside the visible shortcut (e.g. ⇧⌃↑ for Mission Control).
    static let hiddenIDs: Set<Int> = [34, 35, 37, 80, 82]

    private static let defaults: [Int: Default] = {
        var d: [Int: Default] = [
            7: Default(name: "Move focus to the menu bar", code: 120, mods: [.control]),
            8: Default(name: "Move focus to the Dock", code: 99, mods: [.control]),
            9: Default(name: "Move focus to active or next window", code: 118, mods: [.control]),
            10: Default(name: "Move focus to the window toolbar", code: 96, mods: [.control]),
            11: Default(name: "Move focus to the floating window", code: 97, mods: [.control]),
            12: Default(name: "Turn keyboard access on or off", code: 122, mods: [.control]),
            13: Default(name: "Change the way Tab moves focus", code: 98, mods: [.control]),
            27: Default(name: "Move focus to next window", code: 50, mods: [.command]),
            57: Default(name: "Move focus to status menus", code: 100, mods: [.control]),
            28: Default(name: "Save picture of screen as a file", code: 20, mods: [.shift, .command]),
            29: Default(name: "Copy picture of screen to the clipboard", code: 20, mods: [.control, .shift, .command]),
            30: Default(name: "Save picture of selected area as a file", code: 21, mods: [.shift, .command]),
            31: Default(name: "Copy picture of selected area to the clipboard", code: 21, mods: [.control, .shift, .command]),
            184: Default(name: "Screenshot and recording options", code: 23, mods: [.shift, .command]),
            32: Default(name: "Mission Control", code: 126, mods: [.control]),
            33: Default(name: "Application windows", code: 125, mods: [.control]),
            36: Default(name: "Show Desktop", code: 103),
            52: Default(name: "Turn Dock hiding on/off", code: 2, mods: [.option, .command]),
            60: Default(name: "Select the previous input source", code: 49, mods: [.control]),
            61: Default(name: "Select next source in Input menu", code: 49, mods: [.control, .option]),
            64: Default(name: "Show Spotlight search", code: 49, mods: [.command]),
            65: Default(name: "Show Finder search window", code: 49, mods: [.option, .command]),
            79: Default(name: "Move left a space", code: 123, mods: [.control]),
            81: Default(name: "Move right a space", code: 124, mods: [.control]),
            98: Default(name: "Show Help menu", code: 44, mods: [.shift, .command]),
            162: Default(name: "Accessibility shortcuts panel", code: 96, mods: [.option, .command]),
            190: Default(name: "Quick Note", code: 12, fn: true),
            160: Default(name: "Show Launchpad"),
            163: Default(name: "Show Notification Center"),
            175: Default(name: "Turn Do Not Disturb on/off"),
            222: Default(name: "Turn Stage Manager on/off"),
            15: Default(name: "Zoom: turn on or off", enabled: false),
            17: Default(name: "Zoom in", enabled: false),
            19: Default(name: "Zoom out", enabled: false),
            21: Default(name: "Invert colors", enabled: false),
            25: Default(name: "Increase contrast", enabled: false),
            26: Default(name: "Decrease contrast", enabled: false),
        ]
        // Switch to Desktop 1–9: ⌃1…⌃9, off by default.
        let digitCodes = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (i, code) in digitCodes.enumerated() {
            d[118 + i] = Default(name: "Switch to Desktop \(i + 1)", code: code, mods: [.control], enabled: false)
        }
        return d
    }()

    /// Shortcuts that *are* the app feature they'd collide with (Help search, window cycling),
    /// so an app menu item on the same combo isn't blocked.
    static let passThroughIDs: Set<Int> = [27, 98]

    static func name(for id: Int) -> String { defaults[id]?.name ?? "System shortcut #\(id)" }

    static func read() -> [SystemHotkey] {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let raw = CFPreferencesCopyValue("AppleSymbolicHotKeys" as CFString, domain,
                                         kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
        return parse(raw ?? [:])
    }

    /// Merges the stored overrides onto the defaults. Only entries with a key assigned are returned.
    static func parse(_ raw: [String: Any]) -> [SystemHotkey] {
        var out: [Int: SystemHotkey] = [:]
        for (id, d) in defaults {
            guard let code = d.code else { continue }
            out[id] = SystemHotkey(id: id, name: d.name, keyCode: code, modifiers: d.mods, fn: d.fn, enabled: d.enabled)
        }
        for (key, value) in raw {
            guard let id = Int(key), !hiddenIDs.contains(id), let entry = value as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? false
            if let params = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber], params.count >= 3 {
                let code = params[1].intValue
                guard code != 65535 else { out[id] = nil; continue } // "no key assigned"
                let flags = params[2].intValue
                out[id] = SystemHotkey(id: id, name: name(for: id), keyCode: code,
                                       modifiers: Modifiers(NSEvent.ModifierFlags(rawValue: UInt(flags))),
                                       fn: flags & 0x800000 != 0 && isCharacterKey(code), enabled: enabled)
            } else if let existing = out[id] {
                // Only the on/off state was stored; keep the default key.
                out[id] = SystemHotkey(id: id, name: existing.name, keyCode: existing.keyCode,
                                       modifiers: existing.modifiers, fn: existing.fn, enabled: enabled)
            }
        }
        return out.values.sorted { $0.id < $1.id }
    }

    /// fn is implied on F-keys, arrows and navigation keys, so it only matters on character keys.
    private static func isCharacterKey(_ code: Int) -> Bool { code <= 50 && ![36, 48, 49].contains(code) }
}
