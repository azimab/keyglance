import AppKit

/// `KeyGlance --selftest`: checks the parts that don't need Accessibility access.
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "✓" : "✗") \(name)")
        if !condition { failures += 1 }
    }

    static func run() -> Int32 {
        let layout = KeyLayoutMap.current()
        print("Layout: \(layout.unshifted.count) unshifted chars, \(layout.shifted.count) shifted")

        // AX modifier mask decoding
        check("mask 0 = ⌘", Modifiers(axMask: 0) == [.command])
        check("mask 1 = ⇧⌘", Modifiers(axMask: 1) == [.shift, .command])
        check("mask 6 = ⌃⌥⌘", Modifiers(axMask: 6) == [.control, .option, .command])
        check("mask 8 = no ⌘", Modifiers(axMask: 8).isEmpty)
        check("mask 12 = ⌃ only", Modifiers(axMask: 12) == [.control])
        check("symbol order ⌃⌥⇧⌘", Modifiers([.command, .shift, .option, .control]).symbolString == "⌃⌥⇧⌘")

        // Key resolution
        let n = MenuReader.resolveKey(char: "N", virtualKey: nil, glyph: 0, layout: layout)
        check("'N' resolves to a key with label N", n?.code != nil && n?.label == "N" && n?.impliedShift == false)
        let q = MenuReader.resolveKey(char: "?", virtualKey: nil, glyph: 0, layout: layout)
        check("'?' resolves with implied ⇧", q?.code != nil && q?.impliedShift == true)
        let left = MenuReader.resolveKey(char: nil, virtualKey: nil, glyph: 0x64, layout: layout)
        check("glyph 0x64 = ← (123)", left?.code == 123 && left?.label == "←")
        let f5 = MenuReader.resolveKey(char: nil, virtualKey: nil, glyph: 0x6F + 4, layout: layout)
        check("glyph F5 = 96", f5?.code == 96 && f5?.label == "F5")
        let del = MenuReader.resolveKey(char: "\u{7F}", virtualKey: nil, glyph: 0, layout: layout)
        check("DEL char = ⌫ (51)", del?.code == 51)
        let up = MenuReader.resolveKey(char: "\u{F700}", virtualKey: nil, glyph: 0, layout: layout)
        check("NSUpArrowFunctionKey = ↑ (126)", up?.code == 126)
        check("no shortcut → nil", MenuReader.resolveKey(char: nil, virtualKey: nil, glyph: 0, layout: layout) == nil)
        check("vkey 0 ignored", MenuReader.resolveKey(char: "", virtualKey: 0, glyph: 0, layout: layout) == nil)

        // Every letter on the current layout lands on a drawn key.
        let lettersOnBoard = "abcdefghijklmnopqrstuvwxyz".allSatisfy { c in
            layout.unshifted[String(c)].map { KeyboardGeometry.allCodes.contains($0) } ?? true
        }
        check("all letters map to drawn keys", lettersOnBoard)

        // Geometry: every row is 15 units wide.
        let widths = ([KeyboardGeometry.functionRow] + KeyboardGeometry.rows).map { $0.reduce(0) { $0 + $1.width } }
        check("all rows are 15u wide (\(widths))", widths.allSatisfy { abs($0 - 15) < 0.001 })

        // Fuzzy search
        check("fuzzy: 'nwin' matches 'New Window'", Fuzzy.score("nwin", "New Window") != nil)
        check("fuzzy: 'xyz' doesn't match 'New Window'", Fuzzy.score("xyz", "New Window") == nil)
        check("fuzzy: substring outranks scattered",
              (Fuzzy.score("tab", "New Tab") ?? 0) > (Fuzzy.score("tab", "Toggle Address Bar") ?? 0))

        // Filtering logic on synthetic data
        func s(_ title: String, _ mods: Modifiers, _ key: String, code: Int?, enabled: Bool = true) -> Shortcut {
            Shortcut(id: title, title: title, path: ["File"], modifiers: mods, displayModifiers: mods,
                     keyCode: code, keyLabel: key, enabled: enabled)
        }
        check("⌘C is universal", s("Copy", [.command], "C", code: 8).isUniversal)
        check("⌘N is not universal", !s("New", [.command], "N", code: 45).isUniversal)

        let state = AppState()
        state.hideUniversal = true
        state.hideDisabled = true
        state.setShortcutsForTesting([
            s("New", [.command], "N", code: 45),
            s("New Window", [.shift, .command], "N", code: 45),
            s("Copy", [.command], "C", code: 8),
            s("Archive", [.command], "A", code: 0, enabled: false),
            s("Delete Forever", [.option, .command], "⌦", code: 117),
        ])
        state.filter = [.command]
        check("keyboard ⌘: only New (universal + disabled hidden)", state.exactMatches.map(\.title) == ["New"])
        state.filter = [.shift, .command]
        check("keyboard ⇧⌘: New Window on N", state.keyboardMap[45]?.first?.title == "New Window")
        state.filter = [.option, .command]
        check("⌦ goes to 'Other keys'", state.offKeyboard.map(\.title) == ["Delete Forever"])
        state.filter = [.command]
        check("list ⌘ = superset (3 items)", state.listMatches.count == 3)
        state.search = "win"
        check("list search 'win' → New Window first", state.listMatches.first?.title == "New Window")
        check("hidden universal count = 1", state.hiddenUniversalCount == 1)

        // List packing: menus stay whole in one column; only a menu taller than a column splits.
        func menu(_ name: String, _ count: Int) -> [Shortcut] {
            (0..<count).map { Shortcut(id: "\(name)\($0)", title: "\(name) \($0)", path: [name], modifiers: [.command],
                                       displayModifiers: [.command], keyCode: nil, keyLabel: "X", enabled: true) }
        }
        func isHeader(_ e: ColumnPage.Entry) -> Bool { if case .header = e { return true } else { return false } }
        // 600pt tall: ~18 comfortable rows per column, 4 columns wide.
        let size = CGSize(width: 1196, height: 600)
        let whole = ColumnPage(entries: ShortcutListView.entries(menu("A", 10) + menu("B", 10) + menu("C", 3), grouped: true), size: size)
        check("each menu stays in a single column",
              whole.columns.allSatisfy { col in col.filter(isHeader).count >= 1 && isHeader(col[0]) }
              && whole.columns.flatMap { $0 }.filter(isHeader).count == 3)
        let long = ColumnPage(entries: ShortcutListView.entries(menu("A", 3) + menu("B", 30), grouped: true), size: size)
        let longHeaders = long.columns.flatMap { $0 }.filter(isHeader).count
        check("oversize menu splits without a repeated header", longHeaders == 2 && long.columns.count >= 3 && long.overflow == 0)
        check("oversize menu starts at the top of a fresh column",
              long.columns.allSatisfy { col in col.dropFirst().allSatisfy { !isHeader($0) } })

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
