import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = AppState()
    private lazy var overlay = OverlayController(state: state)
    private let hotkeys = HotkeyMonitor()
    private let pinHotkey = GlobalHotkey()
    /// After the pin hotkey opens the overlay, ignore modifier changes until everything is released,
    /// so letting go of the hotkey's own modifiers doesn't rewrite the filter.
    private var ignoreFlagsUntilRelease = false
    private var statusItem: NSStatusItem!
    private var holdWork: DispatchWorkItem?
    private var prefetchWork: DispatchWorkItem?
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        state.requestPin = { [weak self] in self?.overlay.pin() }
        state.requestClose = { [weak self] in self?.overlay.hide() }
        wireHotkeys()
        hotkeys.start()
        pinHotkey.onPress = { [weak self] in self?.pinHotkeyPressed() }
        pinHotkey.register(state.pinHotkey)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)

        if state.axTrusted {
            prefetchFrontmost()
        } else {
            state.openAccessibilitySettings()
            pollForTrust()
        }
    }

    // MARK: Hold-modifier logic

    private func wireHotkeys() {
        hotkeys.onFlags = { [weak self] mods in self?.handleFlags(mods) }
        hotkeys.onGlobalKeyDown = { [weak self] in
            guard let self else { return }
            cancelHold()
            // ⌘ + a key means the user is using a shortcut, not browsing them.
            if overlay.isVisible && !state.pinned { overlay.hide() }
        }
        hotkeys.onGlobalMouseDown = { [weak self] in
            guard let self else { return }
            cancelHold()
            if overlay.isVisible { overlay.hide() }
        }
        hotkeys.onLocalKeyDown = { [weak self] event in
            guard let self, overlay.isVisible else { return event }
            if event.keyCode == 53 { overlay.hide(); return nil } // esc
            return event
        }
    }

    /// True when `mods` includes at least one modifier the user enabled for hold-to-show.
    private func isHoldTrigger(_ mods: Modifiers) -> Bool { !mods.isDisjoint(with: state.holdModifiers) }

    private func handleFlags(_ mods: Modifiers) {
        if ignoreFlagsUntilRelease {
            if mods.isEmpty { ignoreFlagsUntilRelease = false }
            return
        }
        if overlay.isVisible {
            if state.pinned {
                if !mods.isEmpty { state.filter = mods }
            } else if isHoldTrigger(mods) {
                state.filter = mods // each added modifier narrows the view
            } else {
                overlay.hide()
            }
            return
        }
        if isHoldTrigger(mods) { scheduleHold() } else { cancelHold() }
    }

    private func scheduleHold() {
        cancelHold()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mods = Modifiers(NSEvent.modifierFlags)
            guard isHoldTrigger(mods) else { return }
            overlay.show(pinned: false, filter: mods)
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + state.holdDelay, execute: work)
    }

    private func cancelHold() {
        holdWork?.cancel()
        holdWork = nil
    }

    private func pinHotkeyPressed() {
        cancelHold()
        if overlay.isVisible && state.pinned { overlay.hide(); return }
        overlay.show(pinned: true, filter: defaultPinnedFilter)
        if overlay.isVisible { ignoreFlagsUntilRelease = !Modifiers(NSEvent.modifierFlags).isEmpty }
    }

    private var defaultPinnedFilter: Modifiers { state.viewMode == .keyboard ? [.command] : [] }

    // MARK: App tracking

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if overlay.isVisible { overlay.hide() }
        prefetchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.state.prefetch(app) }
        prefetchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func prefetchFrontmost() {
        if let app = NSWorkspace.shared.frontmostApplication { state.prefetch(app) }
    }

    @objc private func inputSourceChanged() { state.reloadLayout() }

    private func pollForTrust() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted() else { return }
            timer.invalidate()
            state.axTrusted = true
            hotkeys.start() // global key monitors only deliver once trusted
            prefetchFrontmost()
            if let app = state.targetApp { state.setTarget(app) }
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeyGlance")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "App"
        menu.addItem(item("Show Shortcuts for \(appName)", #selector(showFromMenu)))
        menu.addItem(.separator())

        for mode in ViewMode.allCases {
            let i = item("\(mode.title) View", #selector(setViewMode(_:)))
            i.representedObject = mode.rawValue
            i.state = state.viewMode == mode ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(.separator())

        let universal = item("Hide Universal Shortcuts (⌘C, ⌘V…)", #selector(toggleUniversal))
        universal.state = state.hideUniversal ? .on : .off
        menu.addItem(universal)
        let disabled = item("Hide Greyed-Out Items", #selector(toggleDisabled))
        disabled.state = state.hideDisabled ? .on : .off
        menu.addItem(disabled)

        let holdMenu = NSMenu()
        for entry in Modifiers.ordered.reversed() {
            let i = item("\(entry.symbol)  \(entry.name)", #selector(toggleHoldModifier(_:)))
            i.representedObject = entry.mod.rawValue
            i.state = state.holdModifiers.contains(entry.mod) ? .on : .off
            holdMenu.addItem(i)
        }
        holdMenu.addItem(.separator())
        let delayHeader = NSMenuItem(title: "Delay", action: nil, keyEquivalent: "")
        delayHeader.isEnabled = false
        holdMenu.addItem(delayHeader)
        for delay in [0.5, 0.8, 1.2] {
            let i = item(String(format: "%.1fs", delay), #selector(setDelay(_:)))
            i.representedObject = delay
            i.state = abs(state.holdDelay - delay) < 0.01 ? .on : .off
            holdMenu.addItem(i)
        }
        let holdTitle = state.holdModifiers.isEmpty ? "Hold to Show: Off" : "Hold to Show: \(state.holdModifiers.symbols.joined(separator: " "))"
        let holdItem = NSMenuItem(title: holdTitle, action: nil, keyEquivalent: "")
        holdItem.submenu = holdMenu
        menu.addItem(holdItem)

        let hotkeyMenu = NSMenu()
        hotkeyMenu.addItem(item("Record Shortcut…", #selector(recordPinHotkey)))
        if state.pinHotkey != nil { hotkeyMenu.addItem(item("Turn Off", #selector(clearPinHotkey))) }
        let hotkeyTitle = state.pinHotkey.map { "Pinned Shortcut: \($0.display(state.layout))" } ?? "Pinned Shortcut: Off"
        let hotkeyItem = NSMenuItem(title: hotkeyTitle, action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)
        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠︎ Grant Accessibility Access…", #selector(grantAccess)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Quit KeyGlance", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func showFromMenu() {
        // Let the status menu close first so the frontmost app is the real target.
        DispatchQueue.main.async { [self] in
            overlay.show(pinned: true, filter: defaultPinnedFilter)
        }
    }

    @objc private func setViewMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = ViewMode(rawValue: raw) { state.viewMode = mode }
    }

    @objc private func toggleUniversal() { state.hideUniversal.toggle() }
    @objc private func toggleDisabled() { state.hideDisabled.toggle() }
    @objc private func setDelay(_ sender: NSMenuItem) {
        if let d = sender.representedObject as? Double { state.holdDelay = d }
    }
    @objc private func toggleHoldModifier(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int else { return }
        let mod = Modifiers(rawValue: raw)
        if state.holdModifiers.contains(mod) { state.holdModifiers.remove(mod) } else { state.holdModifiers.insert(mod) }
        cancelHold()
    }

    @objc private func recordPinHotkey() {
        DispatchQueue.main.async { [self] in
            pinHotkey.register(nil) // so pressing the current combo records it instead of firing it
            guard let combo = HotkeyRecorder.record(layout: state.layout) else {
                pinHotkey.register(state.pinHotkey)
                return
            }
            if pinHotkey.register(combo) {
                state.pinHotkey = combo
            } else {
                pinHotkey.register(state.pinHotkey)
                let alert = NSAlert()
                alert.messageText = "\(combo.display(state.layout)) is unavailable"
                alert.informativeText = "Another app or the system already uses this shortcut. Try a different one."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func clearPinHotkey() {
        state.pinHotkey = nil
        pinHotkey.register(nil)
    }

    @objc private func grantAccess() {
        state.openAccessibilitySettings()
        pollForTrust()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
