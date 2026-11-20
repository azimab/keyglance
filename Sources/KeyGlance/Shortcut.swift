import AppKit

/// Modifier set independent of AppKit/AX encodings.
struct Modifiers: OptionSet, Hashable, Codable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let control = Modifiers(rawValue: 1 << 0)
    static let option = Modifiers(rawValue: 1 << 1)
    static let shift = Modifiers(rawValue: 1 << 2)
    static let command = Modifiers(rawValue: 1 << 3)

    /// Display order used by macOS menus: ⌃ ⌥ ⇧ ⌘
    static let ordered: [(mod: Modifiers, symbol: String, name: String)] = [
        (.control, "⌃", "Control"),
        (.option, "⌥", "Option"),
        (.shift, "⇧", "Shift"),
        (.command, "⌘", "Command"),
    ]

    init(_ flags: NSEvent.ModifierFlags) {
        var m: Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }

    /// Decode kAXMenuItemCmdModifiersAttribute: bit0 shift, bit1 option, bit2 control, bit3 "no command".
    init(axMask: Int) {
        var m: Modifiers = []
        if axMask & 1 != 0 { m.insert(.shift) }
        if axMask & 2 != 0 { m.insert(.option) }
        if axMask & 4 != 0 { m.insert(.control) }
        if axMask & 8 == 0 { m.insert(.command) }
        self = m
    }

    var eventFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if contains(.control) { f.insert(.control) }
        if contains(.option) { f.insert(.option) }
        if contains(.shift) { f.insert(.shift) }
        if contains(.command) { f.insert(.command) }
        return f
    }

    var symbols: [String] { Modifiers.ordered.filter { contains($0.mod) }.map(\.symbol) }
    var symbolString: String { symbols.joined() }
}

struct Shortcut: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    /// Menu path from the top-level menu down to (not including) the item, e.g. ["File", "Export"].
    let path: [String]
    /// Modifiers you physically hold, including shift implied by symbols like "?".
    let modifiers: Modifiers
    /// Modifiers as the app's menu displays them.
    let displayModifiers: Modifiers
    /// Physical key code (current layout), nil if the character isn't on the layout.
    let keyCode: Int?
    let keyLabel: String
    let enabled: Bool

    var topMenu: String { path.first ?? "" }
    var display: String { displayModifiers.symbolString + keyLabel }
    var isUniversal: Bool { Shortcut.universal.contains(display) }
    var searchText: String { (path + [title]).joined(separator: " › ") }

    /// Shortcuts nearly every Mac app shares — hidden by default so the overlay shows what's unique.
    static let universal: Set<String> = [
        "⌘C", "⌘V", "⌘X", "⌘A", "⌘Z", "⇧⌘Z", "⌘Q", "⌘W", "⌘H", "⌥⌘H",
        "⌘M", "⌘,", "⌘S", "⌘P", "⌃⌘F", "⌃⌘Q", "⌥⌘V",
    ]
}

enum Fuzzy {
    /// Subsequence match with bonuses for word starts, runs, and substring hits. nil = no match.
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased().filter { $0 != " " })
        guard !q.isEmpty else { return 0 }
        let lowered = text.lowercased()
        let t = Array(lowered)
        var score = 0, ti = 0, last = -2
        for c in q {
            while ti < t.count, t[ti] != c { ti += 1 }
            guard ti < t.count else { return nil }
            score += 1
            if last == ti - 1 { score += 5 }
            if ti == 0 || " ›-_/".contains(t[ti - 1]) { score += 8 }
            last = ti
            ti += 1
        }
        if lowered.contains(query.lowercased()) { score += 40 }
        return score - t.count / 12
    }
}
