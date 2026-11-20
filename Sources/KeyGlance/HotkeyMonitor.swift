import AppKit

/// Global + local NSEvent monitors. Global key/mouse monitors require Accessibility trust,
/// so `start()` is called again once trust is granted.
final class HotkeyMonitor {
    var onFlags: (Modifiers) -> Void = { _ in }
    var onGlobalKeyDown: () -> Void = {}
    var onGlobalMouseDown: () -> Void = {}
    /// Return nil to swallow the event (e.g. Esc closes the pinned panel).
    var onLocalKeyDown: (NSEvent) -> NSEvent? = { $0 }

    private var monitors: [Any] = []

    func start() {
        stop()
        let add: [Any?] = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
                self?.onFlags(Modifiers(e.modifierFlags))
            },
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
                self?.onFlags(Modifiers(e.modifierFlags)); return e
            },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
                self?.onGlobalKeyDown()
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.onGlobalMouseDown()
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                self?.onLocalKeyDown(e) ?? e
            },
        ]
        monitors = add.compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}
