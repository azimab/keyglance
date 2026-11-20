import AppKit
import Carbon

struct KeyDef {
    let code: Int
    let width: CGFloat
    var modifier: Modifiers? = nil
    var isArrows = false
}

/// Physical geometry of a MacBook-style ANSI keyboard (15 units wide per row).
enum KeyboardGeometry {
    static let fKeyCodes = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    private static func keys(_ codes: [Int]) -> [KeyDef] { codes.map { KeyDef(code: $0, width: 1) } }

    static let functionRow: [KeyDef] = [KeyDef(code: 53, width: 1.5)] + fKeyCodes.map { KeyDef(code: $0, width: 1.125) }

    static let rows: [[KeyDef]] = [
        keys([50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]) + [KeyDef(code: 51, width: 2)],
        [KeyDef(code: 48, width: 1.5)] + keys([12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30]) + [KeyDef(code: 42, width: 1.5)],
        [KeyDef(code: 57, width: 1.75)] + keys([0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]) + [KeyDef(code: 36, width: 2.25)],
        [KeyDef(code: 56, width: 2.25, modifier: .shift)] + keys([6, 7, 8, 9, 11, 45, 46, 43, 47, 44])
            + [KeyDef(code: 60, width: 2.75, modifier: .shift)],
        [
            KeyDef(code: 63, width: 1),
            KeyDef(code: 59, width: 1, modifier: .control),
            KeyDef(code: 58, width: 1, modifier: .option),
            KeyDef(code: 55, width: 1.25, modifier: .command),
            KeyDef(code: 49, width: 5.5),
            KeyDef(code: 54, width: 1.25, modifier: .command),
            KeyDef(code: 61, width: 1, modifier: .option),
            KeyDef(code: -1, width: 3, isArrows: true),
        ],
    ]

    static let arrowCodes = (left: 123, right: 124, down: 125, up: 126)

    static let allCodes: Set<Int> = {
        var s = Set((functionRow + rows.flatMap { $0 }).map(\.code))
        s.formUnion([123, 124, 125, 126])
        return s
    }()
}

/// Key labels and character→key lookup for the *current* input source, so non‑US layouts label correctly.
struct KeyLayoutMap {
    private(set) var labels: [Int: String] = [:]
    private(set) var unshifted: [String: Int] = [:]
    private(set) var shifted: [String: Int] = [:]

    static let fixedLabels: [Int: String] = {
        var d: [Int: String] = [
            53: "esc", 51: "delete", 48: "tab", 57: "caps lock", 36: "return", 56: "shift", 60: "shift",
            63: "fn", 59: "control", 58: "option", 61: "option", 55: "command", 54: "command", 49: "space",
            123: "←", 124: "→", 125: "↓", 126: "↑", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 76: "⌤",
        ]
        for (i, c) in KeyboardGeometry.fKeyCodes.enumerated() { d[c] = "F\(i + 1)" }
        d[105] = "F13"; d[107] = "F14"; d[113] = "F15"
        return d
    }()

    /// Carbon menu glyph constants (kMenu*Glyph) → (key code, label).
    static let glyphKeys: [Int: (code: Int, label: String)] = {
        var d: [Int: (Int, String)] = [
            0x02: (48, "⇥"), 0x03: (48, "⇤"), 0x04: (76, "⌤"), 0x09: (49, "Space"), 0x0A: (117, "⌦"),
            0x0B: (36, "↩"), 0x0D: (36, "↩"), 0x17: (51, "⌫"), 0x1B: (53, "⎋"), 0x1C: (71, "⌧"),
            0x62: (116, "⇞"), 0x64: (123, "←"), 0x65: (124, "→"), 0x66: (115, "↖"), 0x67: (114, "Help"),
            0x68: (126, "↑"), 0x69: (119, "↘"), 0x6A: (125, "↓"), 0x6B: (121, "⇟"),
            0x87: (105, "F13"), 0x88: (107, "F14"), 0x89: (113, "F15"),
        ]
        for (i, c) in KeyboardGeometry.fKeyCodes.enumerated() { d[0x6F + i] = (c, "F\(i + 1)") }
        return d
    }()

    /// Control / NSFunctionKey characters that menus use as key equivalents.
    static let specialChars: [UInt32: (code: Int, label: String)] = {
        var d: [UInt32: (Int, String)] = [
            0xF700: (126, "↑"), 0xF701: (125, "↓"), 0xF702: (123, "←"), 0xF703: (124, "→"),
            0xF728: (117, "⌦"), 0xF729: (115, "↖"), 0xF72B: (119, "↘"), 0xF72C: (116, "⇞"), 0xF72D: (121, "⇟"),
            0x0D: (36, "↩"), 0x03: (76, "⌤"), 0x09: (48, "⇥"), 0x20: (49, "Space"), 0x7F: (51, "⌫"),
            0x08: (51, "⌫"), 0x1B: (53, "⎋"),
        ]
        for (i, c) in KeyboardGeometry.fKeyCodes.enumerated() { d[0xF704 + UInt32(i)] = (c, "F\(i + 1)") }
        return d
    }()

    func label(for code: Int) -> String {
        KeyLayoutMap.fixedLabels[code] ?? labels[code] ?? "?"
    }

    static func current() -> KeyLayoutMap {
        var map = KeyLayoutMap()
        guard let layout = layoutData() else { return map.withUSFallback() }
        let printable = (0..<51).filter { ![36, 48, 49].contains($0) } + [93, 94]
        layout.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for code in printable {
                if let s = translate(code, shift: false, layout: ptr), !s.isEmpty {
                    if code < 51 { map.labels[code] = s.uppercased() }
                    if map.unshifted[s.lowercased()] == nil { map.unshifted[s.lowercased()] = code }
                }
                if let s = translate(code, shift: true, layout: ptr), !s.isEmpty, map.shifted[s] == nil {
                    map.shifted[s] = code
                }
            }
        }
        return map.labels.isEmpty ? map.withUSFallback() : map
    }

    private static func layoutData() -> Data? {
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let src = source?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { continue }
            return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        }
        return nil
    }

    private static func translate(_ code: Int, shift: Bool, layout: UnsafePointer<UCKeyboardLayout>) -> String? {
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let mods: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
        let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), mods, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.unicodeScalars.allSatisfy({ $0.properties.isWhitespace || $0.value < 0x20 }) ? nil : s
    }

    private func withUSFallback() -> KeyLayoutMap {
        var m = self
        let us: [Int: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q",
            13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i",
            35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m",
            47: ".", 50: "`",
        ]
        for (code, s) in us {
            m.labels[code] = s.uppercased()
            m.unshifted[s] = code
        }
        return m
    }
}
