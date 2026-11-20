import AppKit
import SwiftUI

/// `KeyGlance --snapshot <dir>`: renders both overlay views with sample data to PNGs (no permissions needed).
enum Snapshot {
    static func run(outputDirectory: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let state = AppState()
        state.hideUniversal = true
        state.hideDisabled = true
        state.axTrusted = true
        state.targetApp = NSRunningApplication.current
        state.setShortcutsForTesting(sample(layout: state.layout))

        let shots: [(String, ViewMode, Modifiers, Bool, String)] = [
            ("keyboard-cmd", .keyboard, [.command], false, ""),
            ("keyboard-shift-cmd", .keyboard, [.shift, .command], false, ""),
            ("list-cmd", .list, [.command], false, ""),
            ("list-all", .list, [], false, ""),
            ("list-search", .list, [], true, "tab"),
        ]
        for (name, mode, filter, pinned, search) in shots {
            state.viewMode = mode
            state.filter = filter
            state.pinned = pinned
            state.search = search
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                let path = "\(outputDirectory)/\(name)-\(appearance == .aqua ? "light" : "dark").png"
                render(OverlayView(state: state), size: OverlayController.size(for: mode), appearance: appearance, to: path)
                print(path)
            }
        }

        // A menu taller than a column, to check how a split menu lines up.
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map(String.init)
        let tools = letters.map { k in
            Shortcut(id: "tools-\(k)", title: "Tool Action \(k)", path: ["Tools"], modifiers: [.control, .option],
                     displayModifiers: [.control, .option], keyCode: nil, keyLabel: k, enabled: true)
        }
        state.setShortcutsForTesting(sample(layout: state.layout) + tools)
        state.viewMode = .list
        state.filter = []
        state.pinned = false
        state.search = ""
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let path = "\(outputDirectory)/list-long-\(appearance == .aqua ? "light" : "dark").png"
            render(OverlayView(state: state), size: OverlayController.size(for: .list), appearance: appearance, to: path)
            print(path)
        }
        // Shortcut Manager window, one shot per section.
        let catalog = ShortcutCatalog(layout: state.layout, persistent: false)
        let browser = AppMenuSnapshot(bundleID: "com.example.browser", name: "Browser", appPath: "/System/Applications/Safari.app",
                                      scannedAt: Date(), shortcuts: sample(layout: state.layout))
        let editor = AppMenuSnapshot(bundleID: "com.example.editor", name: "Editor", appPath: "/System/Applications/TextEdit.app",
                                     scannedAt: Date(), shortcuts: [
            Shortcut(id: "up", title: "Move Line Up", path: ["Selection"], modifiers: [.control], displayModifiers: [.control],
                     keyCode: 126, keyLabel: "↑", enabled: true),
            Shortcut(id: "lock", title: "Lock Document", path: ["File"], modifiers: [.command], displayModifiers: [.command],
                     keyCode: 37, keyLabel: "L", enabled: true),
            Shortcut(id: "line", title: "Go to Line…", path: ["Find"], modifiers: [.command], displayModifiers: [.command],
                     keyCode: 37, keyLabel: "L", enabled: true),
        ])
        catalog.setForTesting(apps: [browser, editor], system: SystemHotkeys.parse([:]), hotkeys: [
            CustomHotkey(name: "Open Terminal", combo: KeyCombo(keyCode: 17, modifiers: [.option, .command]),
                         action: .openApp(path: "/System/Applications/Utilities/Terminal.app")),
            CustomHotkey(name: "Show KeyGlance", combo: KeyCombo(keyCode: 49, modifiers: [.command]), action: .showOverlay),
        ])
        let nav = ManagerNavigation()
        for section in ManagerSection.allCases {
            nav.section = section
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                let path = "\(outputDirectory)/manager-\(section.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
                render(ManagerView(catalog: catalog, nav: nav), size: NSSize(width: 1060, height: 680), appearance: appearance, to: path)
                print(path)
            }
        }
        return 0
    }

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to path: String) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = appearance == .aqua ? .init(white: 0.86, alpha: 1) : .init(white: 0.14, alpha: 1)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func sample(layout: KeyLayoutMap) -> [Shortcut] {
        let rows: [(String, String, Modifiers, String)] = [
            ("File", "New Window", [.command], "N"), ("File", "New Private Window", [.shift, .command], "N"),
            ("File", "New Tab", [.command], "T"), ("File", "Open File…", [.command], "O"),
            ("File", "Open Location…", [.command], "L"), ("File", "Close Window", [.shift, .command], "W"),
            ("File", "Reopen Closed Tab", [.shift, .command], "T"), ("File", "Close Tab", [.command], "W"),
            ("File", "Save As…", [.command], "S"), ("File", "Print…", [.command], "P"),
            ("Edit", "Undo", [.command], "Z"), ("Edit", "Redo", [.shift, .command], "Z"),
            ("Edit", "Cut", [.command], "X"), ("Edit", "Copy", [.command], "C"), ("Edit", "Paste", [.command], "V"),
            ("Edit", "Select All", [.command], "A"), ("Edit", "Find…", [.command], "F"),
            ("Edit", "Find Next", [.command], "G"), ("Edit", "Find Previous", [.shift, .command], "G"),
            ("Edit", "Use Selection for Find", [.command], "E"),
            ("View", "Show Sidebar", [.shift, .command], "L"), ("View", "Reload Page", [.command], "R"),
            ("View", "Actual Size", [.command], "0"), ("View", "Zoom In", [.command], "+"),
            ("View", "Zoom Out", [.command], "-"), ("View", "Enter Full Screen", [.control, .command], "F"),
            ("View", "Show Tab Overview", [.shift, .command], "\\"), ("View", "Show Reader", [.shift, .command], "R"),
            ("History", "Back", [.command], "["), ("History", "Forward", [.command], "]"),
            ("History", "Home", [.shift, .command], "H"), ("History", "Show All History", [.command], "Y"),
            ("Bookmarks", "Add Bookmark…", [.command], "D"), ("Bookmarks", "Show Bookmarks", [.option, .command], "B"),
            ("Bookmarks", "Edit Bookmarks", [.option, .command], "B"),
            ("Develop", "Show Web Inspector", [.option, .command], "I"),
            ("Develop", "Show JavaScript Console", [.option, .command], "C"),
            ("Window", "Minimize", [.command], "M"), ("Window", "Show Previous Tab", [.shift, .command], "["),
            ("Window", "Show Next Tab", [.shift, .command], "]"), ("Window", "Show Downloads", [.option, .command], "L"),
            ("Help", "Search Help", [.shift, .command], "?"),
        ]
        return rows.compactMap { menu, title, mods, char in
            guard let key = MenuReader.resolveKey(char: char, virtualKey: nil, glyph: 0, layout: layout) else { return nil }
            var effective = mods
            if key.impliedShift { effective.insert(.shift) }
            return Shortcut(id: menu + title, title: title, path: [menu], modifiers: effective, displayModifiers: mods,
                            keyCode: key.code, keyLabel: key.label, enabled: true)
        } + [
            Shortcut(id: "go-top", title: "Scroll to Top", path: ["View"], modifiers: [.command],
                     displayModifiers: [.command], keyCode: 115, keyLabel: "↖", enabled: true),
            Shortcut(id: "prev-page", title: "Previous Page", path: ["History"], modifiers: [.command],
                     displayModifiers: [.command], keyCode: 123, keyLabel: "←", enabled: true),
        ]
    }
}
