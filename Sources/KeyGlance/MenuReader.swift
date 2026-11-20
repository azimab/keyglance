import AppKit
import ApplicationServices

/// Walks an app's menu bar through the Accessibility API and extracts key equivalents.
enum MenuReader {
    private static let itemAttributes: [CFString] = [
        kAXTitleAttribute as CFString,
        kAXMenuItemCmdCharAttribute as CFString,
        kAXMenuItemCmdModifiersAttribute as CFString,
        kAXMenuItemCmdVirtualKeyAttribute as CFString,
        kAXMenuItemCmdGlyphAttribute as CFString,
        kAXEnabledAttribute as CFString,
        kAXChildrenAttribute as CFString,
    ]

    static func readShortcuts(pid: pid_t, layout: KeyLayoutMap) -> [Shortcut] {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar = attribute(app, kAXMenuBarAttribute as CFString).flatMap(asElement) else { return [] }

        var out: [Shortcut] = []
        var seen = Set<String>()
        for (index, top) in elements(attribute(menuBar, kAXChildrenAttribute as CFString)).enumerated() {
            if index == 0 { continue } // Apple menu: system-wide, not the app's
            let title = attribute(top, kAXTitleAttribute as CFString) as? String ?? ""
            for menu in elements(attribute(top, kAXChildrenAttribute as CFString)) {
                walk(menu, path: [title], depth: 0, layout: layout, out: &out, seen: &seen)
            }
        }
        return out
    }

    private static func walk(_ menu: AXUIElement, path: [String], depth: Int, layout: KeyLayoutMap,
                             out: inout [Shortcut], seen: inout Set<String>) {
        guard depth < 6 else { return }
        for item in elements(attribute(menu, kAXChildrenAttribute as CFString)) {
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, itemAttributes as CFArray,
                                                         AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let values = raw as? [AnyObject], values.count == itemAttributes.count else { continue }
            // Missing attributes come back as AXValue error placeholders.
            func value(_ i: Int) -> AnyObject? {
                CFGetTypeID(values[i]) == AXValueGetTypeID() ? nil : values[i]
            }

            let title = (value(0) as? String ?? "").trimmingCharacters(in: .whitespaces)
            let submenus = elements(value(6))
            if !submenus.isEmpty {
                for sub in submenus { walk(sub, path: path + [title], depth: depth + 1, layout: layout, out: &out, seen: &seen) }
                continue
            }
            guard !title.isEmpty,
                  let key = resolveKey(char: value(1) as? String,
                                       virtualKey: (value(3) as? NSNumber)?.intValue,
                                       glyph: (value(4) as? NSNumber)?.intValue ?? 0,
                                       layout: layout) else { continue }

            let displayMods = Modifiers(axMask: (value(2) as? NSNumber)?.intValue ?? 0)
            var mods = displayMods
            if key.impliedShift { mods.insert(.shift) }
            let id = (path + [title]).joined(separator: "›") + "|" + displayMods.symbolString + key.label
            guard seen.insert(id).inserted else { continue }

            out.append(Shortcut(id: id, title: title, path: path, modifiers: mods, displayModifiers: displayMods,
                                keyCode: key.code, keyLabel: key.label,
                                enabled: (value(5) as? NSNumber)?.boolValue ?? true))
        }
    }

    static func resolveKey(char: String?, virtualKey: Int?, glyph: Int, layout: KeyLayoutMap)
        -> (code: Int?, label: String, impliedShift: Bool)? {
        if glyph != 0, let g = KeyLayoutMap.glyphKeys[glyph] { return (g.code, g.label, false) }
        if let char, !char.isEmpty {
            if let scalar = char.unicodeScalars.first, let s = KeyLayoutMap.specialChars[scalar.value] {
                return (s.code, s.label, false)
            }
            if let code = layout.unshifted[char.lowercased()] { return (code, char.uppercased(), false) }
            if let code = layout.shifted[char] { return (code, char, true) }
            return (nil, char.uppercased(), false)
        }
        // Virtual key 0 is "A" but is also what many apps report for "none", so ignore it.
        if let virtualKey, virtualKey > 0 { return (virtualKey, layout.label(for: virtualKey), false) }
        return nil
    }

    // MARK: - AX helpers

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private static func asElement(_ obj: AnyObject) -> AXUIElement? {
        CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
    }

    private static func elements(_ obj: AnyObject?) -> [AXUIElement] {
        guard let array = obj as? [AnyObject] else { return [] }
        return array.compactMap(asElement)
    }
}
