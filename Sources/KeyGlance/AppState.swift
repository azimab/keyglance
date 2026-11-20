import AppKit
import Combine

enum ViewMode: String, CaseIterable {
    case keyboard, list
    var title: String { self == .keyboard ? "Keyboard" : "List" }
}

final class AppState: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var targetApp: NSRunningApplication?
    @Published private(set) var shortcuts: [Shortcut] = []
    @Published private(set) var isLoading = false
    @Published var filter: Modifiers = [.command]
    @Published var pinned = false
    @Published var search = ""
    @Published var hoveredKey: Int?
    @Published var axTrusted = AXIsProcessTrusted()
    @Published private(set) var layout = KeyLayoutMap.current()

    @Published var viewMode: ViewMode { didSet { defaults.set(viewMode.rawValue, forKey: "viewMode") } }
    @Published var hideUniversal: Bool { didSet { defaults.set(hideUniversal, forKey: "hideUniversal") } }
    @Published var hideDisabled: Bool { didSet { defaults.set(hideDisabled, forKey: "hideDisabled") } }
    @Published var holdDelay: Double { didSet { defaults.set(holdDelay, forKey: "holdDelay") } }
    /// Modifiers that open the overlay when held. Empty = hold-to-show is off.
    @Published var holdModifiers: Modifiers { didSet { defaults.set(holdModifiers.rawValue, forKey: "holdModifiers") } }
    /// Optional dedicated shortcut that opens the overlay already pinned.
    @Published var pinHotkey: KeyCombo? {
        didSet {
            defaults.set(pinHotkey?.keyCode ?? -1, forKey: "pinHotkeyCode")
            defaults.set(pinHotkey?.modifiers.rawValue ?? 0, forKey: "pinHotkeyModifiers")
        }
    }

    /// Wired by AppDelegate so views can ask the panel to pin/close.
    var requestPin: () -> Void = {}
    var requestClose: () -> Void = {}

    private var cache: [pid_t: (date: Date, items: [Shortcut])] = [:]
    private var inFlight = Set<pid_t>()

    init() {
        defaults.register(defaults: ["viewMode": ViewMode.keyboard.rawValue, "hideUniversal": true,
                                     "hideDisabled": true, "holdDelay": 0.8,
                                     "holdModifiers": Modifiers([.command, .option, .control, .shift]).rawValue,
                                     "pinHotkeyCode": -1, "pinHotkeyModifiers": 0])
        viewMode = ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .keyboard
        hideUniversal = defaults.bool(forKey: "hideUniversal")
        hideDisabled = defaults.bool(forKey: "hideDisabled")
        holdDelay = defaults.double(forKey: "holdDelay")
        holdModifiers = Modifiers(rawValue: defaults.integer(forKey: "holdModifiers"))
        let code = defaults.integer(forKey: "pinHotkeyCode")
        pinHotkey = code >= 0
            ? KeyCombo(keyCode: code, modifiers: Modifiers(rawValue: defaults.integer(forKey: "pinHotkeyModifiers")))
            : nil
    }

    // MARK: Loading

    /// Make `app` the overlay's subject: show cached results instantly, refresh in the background.
    func setTarget(_ app: NSRunningApplication) {
        targetApp = app
        shortcuts = cache[app.processIdentifier]?.items ?? []
        refresh(app, maxAge: 2)
    }

    /// Warm the cache when an app becomes frontmost so the overlay opens instantly.
    func prefetch(_ app: NSRunningApplication) { refresh(app, maxAge: 30) }

    func reloadLayout() {
        layout = KeyLayoutMap.current()
        cache.removeAll()
        if let app = targetApp { setTarget(app) }
    }

    private func refresh(_ app: NSRunningApplication, maxAge: TimeInterval) {
        let pid = app.processIdentifier
        guard axTrusted, !inFlight.contains(pid) else { return }
        if let cached = cache[pid], Date().timeIntervalSince(cached.date) < maxAge { return }
        inFlight.insert(pid)
        if targetApp?.processIdentifier == pid, shortcuts.isEmpty { isLoading = true }
        let layout = self.layout
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = MenuReader.readShortcuts(pid: pid, layout: layout)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(pid)
                self.cache[pid] = (Date(), items)
                if self.targetApp?.processIdentifier == pid {
                    self.shortcuts = items
                    self.isLoading = false
                }
            }
        }
    }

    func setShortcutsForTesting(_ items: [Shortcut]) { shortcuts = items }

    // MARK: Derived views of the data

    var baseShortcuts: [Shortcut] {
        shortcuts.filter { (!hideDisabled || $0.enabled) && (!hideUniversal || !$0.isUniversal) }
    }

    var hiddenUniversalCount: Int {
        hideUniversal ? shortcuts.filter { $0.isUniversal && (!hideDisabled || $0.enabled) }.count : 0
    }

    /// Keyboard view: what each key does with exactly the held modifiers.
    var exactMatches: [Shortcut] { baseShortcuts.filter { $0.modifiers == filter } }

    var keyboardMap: [Int: [Shortcut]] {
        Dictionary(grouping: exactMatches.filter { $0.keyCode != nil }, by: { $0.keyCode! })
    }

    var offKeyboard: [Shortcut] {
        exactMatches.filter { $0.keyCode.map { !KeyboardGeometry.allCodes.contains($0) } ?? true }
    }

    /// List view: every shortcut that uses at least the held modifiers, fuzzy-filtered by search.
    var listMatches: [Shortcut] {
        let narrowed = baseShortcuts.filter { $0.modifiers.isSuperset(of: filter) }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return narrowed }
        return narrowed
            .compactMap { s -> (Shortcut, Int)? in
                let titleScore = Fuzzy.score(q, s.title).map { $0 + 15 }
                let pathScore = Fuzzy.score(q, s.searchText)
                guard let best = [titleScore, pathScore].compactMap({ $0 }).max() else { return nil }
                return (s, best)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    func toggleFilter(_ mod: Modifiers) {
        if filter.contains(mod) { filter.remove(mod) } else { filter.insert(mod) }
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
