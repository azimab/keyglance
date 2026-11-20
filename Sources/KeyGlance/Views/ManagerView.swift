import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ManagerSection: String, CaseIterable, Identifiable {
    case all, conflicts, hotkeys, remaps
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Shortcuts"
        case .conflicts: return "Conflicts"
        case .hotkeys: return "Universal Hotkeys"
        case .remaps: return "Menu Remaps"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "list.bullet.rectangle"
        case .conflicts: return "exclamationmark.triangle"
        case .hotkeys: return "globe"
        case .remaps: return "arrow.triangle.swap"
        }
    }
}

final class ManagerNavigation: ObservableObject {
    @Published var section: ManagerSection = .all
}

/// The "Shortcut Manager" window, opened from the menu bar.
final class ManagerWindowController: NSObject, NSWindowDelegate {
    private let catalog: ShortcutCatalog
    private let nav = ManagerNavigation()
    private var window: NSWindow?

    init(catalog: ShortcutCatalog) {
        self.catalog = catalog
    }

    func show(_ section: ManagerSection) {
        nav.section = section
        catalog.refreshSystem()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Shortcut Manager"
            w.minSize = NSSize(width: 820, height: 480)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ManagerView(catalog: catalog, nav: nav))
            w.center()
            w.setFrameAutosaveName("ShortcutManager")
            w.delegate = self
            window = w
        }
        // Accessory apps need a regular activation policy for the window to come forward with a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct ManagerView: View {
    @ObservedObject var catalog: ShortcutCatalog
    @ObservedObject var nav: ManagerNavigation

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                Group {
                    switch nav.section {
                    case .all: AllShortcutsView(catalog: catalog)
                    case .conflicts: ConflictsView(catalog: catalog, nav: nav)
                    case .hotkeys: HotkeysView(catalog: catalog)
                    case .remaps: RemapsView(catalog: catalog)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ManagerSection.allCases) { section in
                Button { nav.section = section } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.symbol).frame(width: 18)
                        Text(section.title).lineLimit(1)
                        Spacer(minLength: 4)
                        if let n = badge(section), n > 0 {
                            Text("\(n)")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(section == .conflicts ? Color.orange.opacity(0.25) : Color.primary.opacity(0.1)))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(nav.section == section ? Color.accentColor.opacity(0.18) : Color.clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                Text("\(catalog.apps.count) apps scanned")
                Text("\(catalog.system.filter(\.enabled).count) macOS shortcuts on")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .padding(8)
        .padding(.top, 6)
        .background(Color.primary.opacity(0.03))
    }

    private func badge(_ section: ManagerSection) -> Int? {
        switch section {
        case .all: return nil
        case .conflicts: return catalog.conflicts.count
        case .hotkeys: return catalog.customHotkeys.count
        case .remaps: return catalog.remaps.count
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(nav.section.title).font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let progress = catalog.scanProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 120)
                Text("Scanning \(progress.done)/\(progress.total)…").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Button { catalog.scanRunningApps() } label: {
                    Label("Scan Running Apps", systemImage: "arrow.clockwise")
                }
                .disabled(!AXIsProcessTrusted())
                .help("Reads the menus of every open app. Apps you've used with KeyGlance are remembered.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        switch nav.section {
        case .all: return "Menu shortcuts from every app KeyGlance has scanned, plus macOS and KeyGlance's own global shortcuts."
        case .conflicts: return "Shortcuts that are blocked or used twice. Apps that aren't running use their last scan."
        case .hotkeys: return "Shortcuts that work in every app while KeyGlance is running."
        case .remaps: return "Custom menu shortcuts for specific apps, or every app. Apps pick them up when relaunched."
        }
    }
}

// MARK: - All shortcuts

struct AllShortcutsView: View {
    @ObservedObject var catalog: ShortcutCatalog
    @State private var search = ""
    @State private var source = "all"
    @State private var conflictsOnly = false
    @State private var selection: CatalogEntry.ID?

    private var rows: [CatalogEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return catalog.entries.filter { e in
            switch source {
            case "all": break
            case "global": if !e.isGlobal { return false }
            default: if e.bundleID != source { return false }
            }
            if conflictsOnly && !catalog.conflictedIDs.contains(e.id) { return false }
            if q.isEmpty { return true }
            return Fuzzy.score(q, e.fullTitle + " " + e.sourceName) != nil
                || e.combo.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search shortcuts, menus, apps or combos", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

                Picker("Source", selection: $source) {
                    Text("All sources").tag("all")
                    Text("Global (macOS + KeyGlance)").tag("global")
                    Divider()
                    ForEach(catalog.apps.values.sorted { $0.name < $1.name }, id: \.bundleID) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                .frame(width: 230)
                Toggle("Conflicts only", isOn: $conflictsOnly)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Table(rows, selection: $selection) {
                TableColumn("Shortcut") { e in
                    Text(e.combo)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(catalog.conflictedIDs.contains(e.id) ? Color.orange : Color.primary)
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn("Action") { e in
                    HStack(spacing: 6) {
                        if catalog.conflictedIDs.contains(e.id) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("Part of a conflict — see Conflicts")
                        }
                        Text(e.title).foregroundStyle(e.active ? .primary : .secondary)
                        if e.remapped { Tag(text: "custom") }
                        if !e.active { Tag(text: "off") }
                    }
                }
                .width(min: 180, ideal: 280)
                TableColumn("Menu") { e in
                    Text(e.path.joined(separator: " › ")).foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 180)
                TableColumn("Source") { e in SourceLabel(entry: e, catalog: catalog) }
                    .width(min: 110, ideal: 160)
            }
            .contextMenu(forSelectionType: CatalogEntry.ID.self) { ids in
                if let id = ids.first, let entry = catalog.entries.first(where: { $0.id == id }) {
                    EntryActions(entry: entry, catalog: catalog)
                }
            }
        }
    }
}

/// Context actions for a row, used by the table and conflict cards.
struct EntryActions: View {
    let entry: CatalogEntry
    @ObservedObject var catalog: ShortcutCatalog

    var body: some View {
        switch entry.source {
        case .app:
            Button("Change Shortcut in \(entry.sourceName)…") { ManagerActions.remap(entry, allApps: false, catalog: catalog) }
            Button("Change Shortcut in All Apps…") { ManagerActions.remap(entry, allApps: true, catalog: catalog) }
            let existing = catalog.remaps(for: entry)
            if !existing.isEmpty {
                Button("Reset to App's Default") { ManagerActions.remove(existing, catalog: catalog) }
            }
            Divider()
            Button("Forget \(entry.sourceName)'s Scan") { catalog.forget(entry.bundleID!) }
        case .system:
            Button("Open Keyboard Shortcuts Settings…") { ManagerActions.openSystemShortcuts() }
        case .keyglance:
            if let id = entry.hotkeyID, let hotkey = catalog.customHotkeys.first(where: { $0.id == id }) {
                Button("Change Hotkey…") { ManagerActions.changeCombo(hotkey, catalog: catalog) }
                Button("Delete Hotkey") { catalog.removeHotkey(id) }
            } else {
                Text("Change it under Pinned Shortcut in the menu bar")
            }
        }
    }
}

struct SourceLabel: View {
    let entry: CatalogEntry
    @ObservedObject var catalog: ShortcutCatalog

    var body: some View {
        HStack(spacing: 6) {
            switch entry.source {
            case .system: Image(systemName: "gearshape").frame(width: 16)
            case .keyglance: Image(systemName: "keyboard").frame(width: 16)
            case let .app(id):
                if let icon = AppIcons.icon(path: catalog.apps[id]?.appPath) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
            }
            Text(entry.sourceName).lineLimit(1)
        }
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(path: String?) -> NSImage? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
    }
}

struct KeyCap: View {
    let text: String
    var tint: Color = .primary

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(minWidth: 54, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.14)))
    }
}

// MARK: - Conflicts

struct ConflictsView: View {
    @ObservedObject var catalog: ShortcutCatalog
    @ObservedObject var nav: ManagerNavigation

    var body: some View {
        if catalog.conflicts.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal").font(.system(size: 34)).foregroundStyle(.green)
                Text("No conflicts among \(catalog.apps.count) scanned apps").font(.headline)
                Text("Scan your running apps to check more of them.").foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Conflict.Kind.allCases, id: \.self) { kind in
                        let items = catalog.conflicts.filter { $0.kind == kind }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(kind.title).font(.system(size: 14, weight: .semibold))
                                    Text("\(items.count)").foregroundStyle(.secondary)
                                }
                                Text(kind.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                                ForEach(items) { ConflictCard(conflict: $0, catalog: catalog) }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }
}

struct ConflictCard: View {
    let conflict: Conflict
    @ObservedObject var catalog: ShortcutCatalog

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            KeyCap(text: conflict.combo, tint: .orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(conflict.headline).font(.system(size: 13, weight: .medium)).lineLimit(2)
                ForEach(conflict.entries) { e in
                    HStack(spacing: 6) {
                        SourceLabel(entry: e, catalog: catalog).font(.system(size: 12))
                        Text("·").foregroundStyle(.tertiary)
                        Text(e.fullTitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 10)
            Menu("Fix…") {
                ForEach(conflict.entries) { e in
                    Section(e.title) { EntryActions(entry: e, catalog: catalog) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Universal hotkeys

struct HotkeysView: View {
    @ObservedObject var catalog: ShortcutCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu {
                    Button("Open an App…") { ManagerActions.addHotkey(.app, catalog: catalog) }
                    Button("Open a URL…") { ManagerActions.addHotkey(.url, catalog: catalog) }
                    Button("Run a Shell Command…") { ManagerActions.addHotkey(.shell, catalog: catalog) }
                    Button("Show KeyGlance Cheat Sheet") { ManagerActions.addHotkey(.overlay, catalog: catalog) }
                } label: {
                    Label("Add Hotkey", systemImage: "plus")
                }
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            if catalog.customHotkeys.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "globe").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("No universal hotkeys yet").font(.headline)
                    Text("Add one to open an app, a URL or run a command from anywhere.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(catalog.customHotkeys) { HotkeyRow(hotkey: $0, catalog: catalog) }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
    }
}

struct HotkeyRow: View {
    let hotkey: CustomHotkey
    @ObservedObject var catalog: ShortcutCatalog

    var body: some View {
        let failed = catalog.failedHotkeys.contains(hotkey.id)
        let conflicted = catalog.conflictedIDs.contains("kg-\(hotkey.id)")
        HStack(spacing: 14) {
            Toggle("", isOn: Binding(get: { hotkey.enabled }, set: { on in
                var h = hotkey
                h.enabled = on
                catalog.updateHotkey(h)
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            KeyCap(text: hotkey.combo.display(catalog.layout), tint: failed || conflicted ? .orange : .primary)
            Group {
                if case let .openApp(path) = hotkey.action, let icon = AppIcons.icon(path: path) {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                } else {
                    Image(systemName: hotkey.action.symbol).foregroundStyle(.secondary)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(hotkey.name).font(.system(size: 13, weight: .medium))
                Text(hotkey.action.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                if failed {
                    Text("macOS refused this combo. Another app (or KeyGlance's Pinned Shortcut) already registered it.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                } else if conflicted {
                    Text("Blocks or clashes with other shortcuts — see Conflicts.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Run") { catalog.run(hotkey.action) }
            Button("Change…") { ManagerActions.changeCombo(hotkey, catalog: catalog) }
            Button { catalog.removeHotkey(hotkey.id) } label: { Image(systemName: "trash") }
                .help("Delete")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .opacity(hotkey.enabled ? 1 : 0.6)
    }
}

// MARK: - Menu remaps

struct RemapsView: View {
    @ObservedObject var catalog: ShortcutCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("To add one, right-click a menu item under All Shortcuts or Conflicts. Only native Mac apps honor custom menu shortcuts; Electron apps ignore them.",
                  systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 12)
            if catalog.remaps.isEmpty {
                Text("No custom menu shortcuts").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(catalog.remaps) { remap in
                            HStack(spacing: 14) {
                                KeyCap(text: MenuRemapper.decode(remap.value, layout: catalog.layout))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(remap.menuPath).font(.system(size: 13, weight: .medium))
                                    Text(remap.bundleID == nil ? "Every app with this menu item" : remap.appName)
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Remove") { ManagerActions.remove([remap], catalog: catalog) }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
    }
}

// MARK: - Actions (modal prompts)

enum NewHotkeyKind { case app, url, shell, overlay }

enum ManagerActions {
    static func addHotkey(_ kind: NewHotkeyKind, catalog: ShortcutCatalog) {
        DispatchQueue.main.async {
            let name: String
            let action: HotkeyAction
            switch kind {
            case .app:
                let panel = NSOpenPanel()
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                panel.allowedContentTypes = [.applicationBundle]
                panel.prompt = "Choose"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                action = .openApp(path: url.path)
                name = "Open " + FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            case .url:
                guard let url = prompt("Open a URL", detail: "Any link, including app links like x-apple.systempreferences:",
                                       placeholder: "https://…"), !url.isEmpty else { return }
                action = .openURL(url)
                name = "Open " + (URL(string: url)?.host ?? url)
            case .shell:
                guard let command = prompt("Run a Shell Command", detail: "Runs with zsh as a login shell. Output is discarded.",
                                           placeholder: "open ~/Downloads"), !command.isEmpty else { return }
                action = .shell(command)
                name = "Run " + String(command.prefix(40))
            case .overlay:
                action = .showOverlay
                name = "Show KeyGlance"
            }
            catalog.suspendHotkeys()
            guard let combo = HotkeyRecorder.record(layout: catalog.layout, message: "Hotkey for “\(name)”.") else {
                catalog.applyHotkeys()
                return
            }
            let hotkey = CustomHotkey(name: name, combo: combo, action: action)
            catalog.addHotkey(hotkey)
            report(hotkey, catalog: catalog)
        }
    }

    static func changeCombo(_ hotkey: CustomHotkey, catalog: ShortcutCatalog) {
        DispatchQueue.main.async {
            catalog.suspendHotkeys()
            guard let combo = HotkeyRecorder.record(layout: catalog.layout, message: "New hotkey for “\(hotkey.name)”.") else {
                catalog.applyHotkeys()
                return
            }
            var h = hotkey
            h.combo = combo
            catalog.updateHotkey(h)
            report(h, catalog: catalog)
        }
    }

    /// Warns right away when a new hotkey failed to register or will block app shortcuts.
    private static func report(_ hotkey: CustomHotkey, catalog: ShortcutCatalog) {
        let combo = hotkey.combo.display(catalog.layout)
        if catalog.failedHotkeys.contains(hotkey.id) {
            alert("\(combo) is unavailable",
                  "macOS refused it, usually because another app or KeyGlance already uses it. The hotkey is saved but won't fire until you change it.")
            return
        }
        let hits = catalog.conflicts.filter { $0.entries.contains { $0.hotkeyID == hotkey.id } }
        guard !hits.isEmpty else { return }
        alert("\(combo) overlaps other shortcuts",
              hits.prefix(6).map { "• " + $0.headline }.joined(separator: "\n")
                + "\n\nYour hotkey wins in every app, so those shortcuts stop working while KeyGlance runs.")
    }

    static func remap(_ entry: CatalogEntry, allApps: Bool, catalog: ShortcutCatalog) {
        DispatchQueue.main.async {
            let scope = allApps ? "every app" : entry.sourceName
            guard let combo = HotkeyRecorder.record(layout: catalog.layout,
                                                   message: "New shortcut for “\(entry.title)” in \(scope).") else { return }
            let display = combo.display(catalog.layout)
            guard catalog.setRemap(for: entry, combo: combo, allApps: allApps) else {
                var why = "macOS didn't accept the change."
                if !allApps, let id = entry.bundleID, MenuRemapper.isSandboxed(id) {
                    why += " \(entry.sourceName) is sandboxed, so its settings live in a container KeyGlance can't write to. Try “Change Shortcut in All Apps” instead."
                }
                alert("Couldn't set \(display)", why)
                return
            }
            var info = "Quit and reopen \(allApps ? "your apps" : entry.sourceName) to apply it."
            if let id = entry.bundleID, !allApps, MenuRemapper.isSandboxed(id) {
                info += "\n\n\(entry.sourceName) is sandboxed and may not read this setting. If it doesn't change, use “Change Shortcut in All Apps” instead."
            }
            alert("\(display) set for “\(entry.title)”", info)
        }
    }

    static func remove(_ remaps: [MenuRemap], catalog: ShortcutCatalog) {
        let failed = remaps.filter { !catalog.removeRemap($0) }
        if !failed.isEmpty {
            alert("Couldn't remove the custom shortcut", "macOS didn't accept the change.")
        }
    }

    static func openSystemShortcuts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func prompt(_ title: String, detail: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Next")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
