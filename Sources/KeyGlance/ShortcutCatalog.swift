import AppKit
import Combine

/// The last menu scan of one app, kept on disk so apps that aren't running still count.
struct AppMenuSnapshot: Codable, Equatable {
    let bundleID: String
    let name: String
    let appPath: String?
    let scannedAt: Date
    let shortcuts: [Shortcut]
}

/// One row of the cross-app list: an app's menu item, a macOS system shortcut, or a KeyGlance hotkey.
struct CatalogEntry: Identifiable, Hashable {
    enum Source: Hashable {
        case system, keyglance, app(String)
    }

    let id: String
    let source: Source
    let sourceName: String
    let combo: String
    /// Same key + modifiers ⇔ same matchKey. nil when there's no key to compare.
    let matchKey: String?
    let title: String
    let path: [String]
    /// Counts toward conflicts. App menu items always do (enabled state is contextual);
    /// system and KeyGlance shortcuts only when switched on.
    let active: Bool
    var remapped = false
    var hotkeyID: UUID? = nil

    var isGlobal: Bool { if case .app = source { return false } else { return true } }
    var bundleID: String? { if case let .app(id) = source { return id } else { return nil } }
    var fullTitle: String { (path + [title]).joined(separator: " › ") }

    static func matchKey(code: Int?, label: String, modifiers: Modifiers, fn: Bool = false) -> String {
        (fn ? "fn+" : "") + (code.map { "k\($0)" } ?? "c" + label.uppercased()) + "|\(modifiers.rawValue)"
    }
}

struct Conflict: Identifiable, Hashable {
    enum Kind: Int, CaseIterable, Comparable {
        case shadowed, globalClash, inApp

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .shadowed: return "Blocked app shortcuts"
            case .globalClash: return "Clashing global shortcuts"
            case .inApp: return "Duplicates inside an app"
            }
        }

        var explanation: String {
            switch self {
            case .shadowed: return "A system or KeyGlance shortcut takes this combo first, so the app's menu item never receives it."
            case .globalClash: return "Two global shortcuts share a combo. Only one of them fires."
            case .inApp: return "One app uses the same combo for two different menu items. Usually only one works at a time."
            }
        }
    }

    let id: String
    let kind: Kind
    let combo: String
    let entries: [CatalogEntry]

    var headline: String {
        switch kind {
        case .shadowed:
            let globals = entries.filter(\.isGlobal).map(\.title)
            let items = entries.filter { !$0.isGlobal }
            return "\(globals.joined(separator: " / ")) blocks \(items.first?.sourceName ?? ""): "
                + uniqueTitles(items).joined(separator: ", ")
        case .globalClash:
            return entries.map { "\($0.title) (\($0.sourceName))" }.joined(separator: " vs ")
        case .inApp:
            return "\(entries.first?.sourceName ?? ""): " + uniqueTitles(entries).joined(separator: " vs ")
        }
    }

    private func uniqueTitles(_ items: [CatalogEntry]) -> [String] {
        var seen = Set<String>()
        return items.map(\.title).filter { seen.insert($0).inserted }
    }
}

/// A custom menu shortcut stored in NSUserKeyEquivalents.
struct MenuRemap: Identifiable, Hashable {
    let bundleID: String? // nil = all apps
    let appName: String
    let itemKey: String
    let value: String

    var id: String { (bundleID ?? "*") + "|" + itemKey }
    var menuPath: String { MenuRemapper.displayPath(itemKey) }
}

/// Every shortcut KeyGlance knows about, across apps, plus the conflicts between them.
final class ShortcutCatalog: ObservableObject {
    @Published private(set) var apps: [String: AppMenuSnapshot] = [:]
    @Published private(set) var system: [SystemHotkey] = []
    @Published private(set) var customHotkeys: [CustomHotkey] = []
    @Published private(set) var failedHotkeys: Set<UUID> = []
    @Published private(set) var remaps: [MenuRemap] = []
    @Published private(set) var entries: [CatalogEntry] = []
    @Published private(set) var conflicts: [Conflict] = []
    @Published private(set) var conflictedIDs: Set<String> = []
    @Published private(set) var scanProgress: (done: Int, total: Int)?

    var pinHotkey: KeyCombo? { didSet { rebuild() } }
    var layout: KeyLayoutMap { didSet { rebuild() } }
    var onShowOverlay: () -> Void = {}

    private let persistent: Bool
    private var tokens: [UUID: UInt32] = [:]
    private var saveWork: DispatchWorkItem?

    init(layout: KeyLayoutMap, persistent: Bool = true) {
        self.layout = layout
        self.persistent = persistent
        if persistent {
            loadApps()
            loadHotkeys()
            system = SystemHotkeys.read()
            reloadRemaps()
        }
        rebuild()
    }

    // MARK: Menus

    /// Called whenever an app's menus are read (overlay prefetch or a full scan).
    func record(_ app: NSRunningApplication, _ items: [Shortcut]) {
        guard let id = app.bundleIdentifier, !items.isEmpty, apps[id]?.shortcuts != items else { return }
        apps[id] = AppMenuSnapshot(bundleID: id, name: app.localizedName ?? id, appPath: app.bundleURL?.path,
                                   scannedAt: Date(), shortcuts: items)
        if !remaps.contains(where: { $0.bundleID == id }) { appendRemaps(for: apps[id]!) }
        rebuild()
        scheduleSave()
    }

    func forget(_ bundleID: String) {
        apps[bundleID] = nil
        rebuild()
        scheduleSave()
    }

    /// Reads the menus of every running app with a menu bar, one at a time in the background.
    func scanRunningApps() {
        guard scanProgress == nil, AXIsProcessTrusted() else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let targets = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != me
        }
        scanProgress = (0, targets.count)
        let layout = self.layout
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for (i, app) in targets.enumerated() {
                let items = MenuReader.readShortcuts(pid: app.processIdentifier, layout: layout)
                DispatchQueue.main.async {
                    self?.record(app, items)
                    self?.scanProgress = (i + 1, targets.count)
                }
            }
            DispatchQueue.main.async {
                self?.scanProgress = nil
                self?.reloadRemaps()
            }
        }
    }

    func refreshSystem() {
        system = SystemHotkeys.read()
        reloadRemaps()
        rebuild()
    }

    // MARK: Universal hotkeys

    func addHotkey(_ hotkey: CustomHotkey) {
        customHotkeys.append(hotkey)
        hotkeysChanged()
    }

    func updateHotkey(_ hotkey: CustomHotkey) {
        guard let i = customHotkeys.firstIndex(where: { $0.id == hotkey.id }) else { return }
        customHotkeys[i] = hotkey
        hotkeysChanged()
    }

    func removeHotkey(_ id: UUID) {
        customHotkeys.removeAll { $0.id == id }
        hotkeysChanged()
    }

    /// Registers every enabled hotkey with the OS. Ones the OS refuses land in `failedHotkeys`.
    func applyHotkeys() {
        suspendHotkeys()
        var failed = Set<UUID>()
        for hotkey in customHotkeys where hotkey.enabled {
            let action = hotkey.action
            if let token = HotkeyCenter.shared.register(hotkey.combo, action: { [weak self] in self?.run(action) }) {
                tokens[hotkey.id] = token
            } else {
                failed.insert(hotkey.id)
            }
        }
        failedHotkeys = failed
    }

    /// Unregisters all custom hotkeys, e.g. while recording a new combo so pressing one records it.
    func suspendHotkeys() {
        tokens.values.forEach { HotkeyCenter.shared.unregister($0) }
        tokens.removeAll()
    }

    func run(_ action: HotkeyAction) { HotkeyActionRunner.run(action, showOverlay: onShowOverlay) }

    private func hotkeysChanged() {
        if persistent {
            UserDefaults.standard.set(try? JSONEncoder().encode(customHotkeys), forKey: "customHotkeys")
            applyHotkeys()
        }
        rebuild()
    }

    private func loadHotkeys() {
        guard let data = UserDefaults.standard.data(forKey: "customHotkeys"),
              let list = try? JSONDecoder().decode([CustomHotkey].self, from: data) else { return }
        customHotkeys = list
    }

    // MARK: Menu remaps

    func reloadRemaps() {
        var out = MenuRemapper.read(nil).map { MenuRemap(bundleID: nil, appName: "All Apps", itemKey: $0.key, value: $0.value) }
        for snap in apps.values {
            out += MenuRemapper.read(snap.bundleID).map {
                MenuRemap(bundleID: snap.bundleID, appName: snap.name, itemKey: $0.key, value: $0.value)
            }
        }
        remaps = out.sorted { ($0.bundleID == nil ? 0 : 1, $0.appName, $0.itemKey) < ($1.bundleID == nil ? 0 : 1, $1.appName, $1.itemKey) }
        rebuild()
    }

    private func appendRemaps(for snap: AppMenuSnapshot) {
        let found = MenuRemapper.read(snap.bundleID).map {
            MenuRemap(bundleID: snap.bundleID, appName: snap.name, itemKey: $0.key, value: $0.value)
        }
        if !found.isEmpty { remaps += found }
    }

    /// Sets (or with nil, removes) a custom shortcut for an app's menu item. `allApps` writes it to the
    /// global domain by title, so every app with an item of that name picks it up.
    func setRemap(for entry: CatalogEntry, combo: KeyCombo?, allApps: Bool) -> Bool {
        guard let bundleID = entry.bundleID else { return false }
        let domain = allApps ? nil : bundleID
        let key = allApps ? entry.title : MenuRemapper.itemKey(title: entry.title, path: entry.path)
        var dict = MenuRemapper.read(domain)
        if let combo {
            guard let value = MenuRemapper.encode(combo, layout: layout) else { return false }
            dict[key] = value
        } else {
            dict[key] = nil
        }
        let ok = MenuRemapper.write(dict, domain)
        reloadRemaps()
        return ok
    }

    func removeRemap(_ remap: MenuRemap) -> Bool {
        var dict = MenuRemapper.read(remap.bundleID)
        dict[remap.itemKey] = nil
        let ok = MenuRemapper.write(dict, remap.bundleID)
        reloadRemaps()
        return ok
    }

    /// Remaps that apply to this menu item (by path or by bare title, per app or for all apps).
    func remaps(for entry: CatalogEntry) -> [MenuRemap] {
        guard let bundleID = entry.bundleID else { return [] }
        let pathKey = MenuRemapper.itemKey(title: entry.title, path: entry.path)
        return remaps.filter {
            ($0.bundleID == bundleID && ($0.itemKey == pathKey || $0.itemKey == entry.title))
                || ($0.bundleID == nil && $0.itemKey == entry.title)
        }
    }

    // MARK: Entries & conflicts

    func setForTesting(apps: [AppMenuSnapshot], system: [SystemHotkey], hotkeys: [CustomHotkey]) {
        self.apps = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })
        self.system = system
        self.customHotkeys = hotkeys
        rebuild()
    }

    func rebuild() {
        var list: [CatalogEntry] = []
        for s in system {
            list.append(CatalogEntry(id: "sys-\(s.id)", source: .system, sourceName: "macOS", combo: s.display(layout),
                                     matchKey: SystemHotkeys.passThroughIDs.contains(s.id) ? nil
                                         : CatalogEntry.matchKey(code: s.keyCode, label: "", modifiers: s.modifiers, fn: s.fn),
                                     title: s.name, path: [], active: s.enabled))
        }
        if let pin = pinHotkey {
            list.append(CatalogEntry(id: "kg-pin", source: .keyglance, sourceName: "KeyGlance", combo: pin.display(layout),
                                     matchKey: CatalogEntry.matchKey(code: pin.keyCode, label: "", modifiers: pin.modifiers),
                                     title: "Open KeyGlance (pinned)", path: [], active: true))
        }
        for h in customHotkeys {
            var e = CatalogEntry(id: "kg-\(h.id)", source: .keyglance, sourceName: "KeyGlance", combo: h.combo.display(layout),
                                 matchKey: CatalogEntry.matchKey(code: h.combo.keyCode, label: "", modifiers: h.combo.modifiers),
                                 title: h.name, path: [], active: h.enabled)
            e.hotkeyID = h.id
            list.append(e)
        }

        let remapKeys = Set(remaps.map(\.id))
        for snap in apps.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            for s in snap.shortcuts {
                var e = CatalogEntry(id: snap.bundleID + "|" + s.id, source: .app(snap.bundleID), sourceName: snap.name,
                                     combo: s.display,
                                     matchKey: CatalogEntry.matchKey(code: s.keyCode, label: s.keyLabel, modifiers: s.modifiers),
                                     title: s.title, path: s.path, active: true)
                e.remapped = remapKeys.contains(snap.bundleID + "|" + MenuRemapper.itemKey(title: s.title, path: s.path))
                    || remapKeys.contains(snap.bundleID + "|" + s.title) || remapKeys.contains("*|" + s.title)
                list.append(e)
            }
        }
        entries = list
        conflicts = Self.findConflicts(list)
        conflictedIDs = Set(conflicts.flatMap { $0.entries.map(\.id) })
    }

    static func findConflicts(_ entries: [CatalogEntry]) -> [Conflict] {
        let usable = entries.filter { $0.active && $0.matchKey != nil }
        let globals = Dictionary(grouping: usable.filter(\.isGlobal), by: { $0.matchKey! })
        var out: [Conflict] = []

        for (key, group) in globals where group.count > 1 {
            out.append(Conflict(id: "g|" + key, kind: .globalClash, combo: group[0].combo, entries: group))
        }

        let byApp = Dictionary(grouping: usable.filter { !$0.isGlobal }, by: { $0.bundleID! })
        for (bundleID, items) in byApp {
            for (key, same) in Dictionary(grouping: items, by: { $0.matchKey! }) {
                if let blockers = globals[key] {
                    out.append(Conflict(id: "s|\(key)|\(bundleID)", kind: .shadowed, combo: same[0].combo,
                                        entries: blockers + same))
                }
                if Set(same.map(\.title)).count > 1 {
                    out.append(Conflict(id: "a|\(key)|\(bundleID)", kind: .inApp, combo: same[0].combo, entries: same))
                }
            }
        }
        return out.sorted { ($0.kind, $0.entries[0].sourceName, $0.combo) < ($1.kind, $1.entries[0].sourceName, $1.combo) }
    }

    // MARK: Persistence

    private static var storeURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("KeyGlance/menus.json")
    }

    private func loadApps() {
        guard let url = Self.storeURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([AppMenuSnapshot].self, from: data) else { return }
        apps = Dictionary(list.map { ($0.bundleID, $0) }, uniquingKeysWith: { $1 })
    }

    private func scheduleSave() {
        guard persistent else { return }
        saveWork?.cancel()
        let snapshot = Array(apps.values)
        let work = DispatchWorkItem {
            guard let url = Self.storeURL, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }
}
