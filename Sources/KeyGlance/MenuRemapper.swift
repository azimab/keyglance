import AppKit
import Security

/// Custom menu shortcuts through `NSUserKeyEquivalents`, the same setting System Settings › Keyboard ›
/// App Shortcuts writes. Apps read it at launch, so a change applies after the app relaunches. Only
/// AppKit apps honor it; Electron and most cross-platform apps ignore it.
enum MenuRemapper {
    private static let key = "NSUserKeyEquivalents" as CFString

    /// nil = every app (the global domain).
    private static func domain(_ bundleID: String?) -> CFString {
        bundleID.map { $0 as CFString } ?? kCFPreferencesAnyApplication
    }

    static func read(_ bundleID: String?) -> [String: String] {
        let d = domain(bundleID)
        return CFPreferencesCopyValue(key, d, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: String] ?? [:]
    }

    /// Writes the whole dictionary and confirms it reads back. False if the domain can't be written
    /// (e.g. a sandboxed app whose settings live in its container).
    static func write(_ dict: [String: String], _ bundleID: String?) -> Bool {
        let d = domain(bundleID)
        CFPreferencesSetValue(key, dict.isEmpty ? nil : dict as CFDictionary, d, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(d, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return false }
        return read(bundleID) == dict
    }

    /// A menu path disambiguates items that share a title: "\u{1b}File\u{1b}Export…".
    static func itemKey(title: String, path: [String]) -> String {
        path.isEmpty ? title : "\u{1b}" + (path + [title]).joined(separator: "\u{1b}")
    }

    static func displayPath(_ itemKey: String) -> String {
        itemKey.split(separator: "\u{1b}").joined(separator: " › ")
    }

    /// "^~$@" prefixes for ⌃⌥⇧⌘, then the key's character.
    static func encode(_ combo: KeyCombo, layout: KeyLayoutMap) -> String? {
        guard let char = character(for: combo.keyCode, layout: layout) else { return nil }
        var s = ""
        if combo.modifiers.contains(.control) { s += "^" }
        if combo.modifiers.contains(.option) { s += "~" }
        if combo.modifiers.contains(.shift) { s += "$" }
        if combo.modifiers.contains(.command) { s += "@" }
        return s + char
    }

    /// Display form ("⇧⌘E") of a stored value. An empty value means "no shortcut".
    static func decode(_ value: String, layout: KeyLayoutMap) -> String {
        var chars = Array(value)
        var mods: Modifiers = []
        let prefixes: [Character: Modifiers] = ["^": .control, "~": .option, "$": .shift, "@": .command]
        while chars.count > 1, let m = prefixes[chars[0]] {
            mods.insert(m)
            chars.removeFirst()
        }
        guard let last = chars.first else { return "none" }
        let label = MenuReader.resolveKey(char: String(last), virtualKey: nil, glyph: 0, layout: layout)?.label
            ?? String(last).uppercased()
        return mods.symbolString + label
    }

    static func character(for code: Int, layout: KeyLayoutMap) -> String? {
        if let special = specialChars[code] { return special }
        return layout.unshifted.filter { $0.value == code }.map(\.key).min()
    }

    private static let specialChars: [Int: String] = {
        var d: [Int: String] = [
            126: "\u{F700}", 125: "\u{F701}", 123: "\u{F702}", 124: "\u{F703}",
            117: "\u{F728}", 115: "\u{F729}", 119: "\u{F72B}", 116: "\u{F72C}", 121: "\u{F72D}",
            36: "\r", 76: "\u{3}", 48: "\t", 49: " ", 51: "\u{8}", 53: "\u{1b}",
        ]
        for (i, code) in KeyboardGeometry.fKeyCodes.enumerated() {
            d[code] = String(UnicodeScalar(0xF704 + UInt32(i))!)
        }
        return d
    }()

    /// Sandboxed apps keep their settings in their container, which other apps can't write to directly.
    static func isSandboxed(_ bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }
}
