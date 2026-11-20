import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating floating panel: shows over the frontmost app without stealing focus.
final class OverlayPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    // Allows the search field to take keystrokes when pinned, without activating our app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    /// Keyboard: header + keyboard (365) + footer, no slack. List: roomier so rows stay readable.
    static func size(for mode: ViewMode) -> NSSize {
        mode == .keyboard ? NSSize(width: 940, height: 460) : NSSize(width: 1240, height: 700)
    }

    private let state: AppState
    private var observers: [AnyCancellable] = []
    private lazy var panel: OverlayPanel = {
        let size = Self.size(for: state.viewMode)
        let panel = OverlayPanel(size: size)
        let host = NSHostingView(rootView: OverlayView(state: state))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = [] // never let SwiftUI content resize the panel
        panel.contentView = host
        return panel
    }()

    init(state: AppState) {
        self.state = state
        observers.append(state.$darkMode.sink { [weak self] dark in
            self?.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        })
        // Resize around the current center when switching views while the panel is up.
        // @Published emits in willSet; hop to the next main-queue turn so the redraw that
        // setFrame triggers sees the new mode rather than the old one.
        observers.append(state.$viewMode.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] mode in
            guard let self, self.panel.isVisible else { return }
            let center = NSPoint(x: self.panel.frame.midX, y: self.panel.frame.midY)
            self.place(size: Self.size(for: mode), center: center, screen: self.panel.screen)
        })
    }

    /// Centers a frame of `size` on `center`, shrunk and nudged to stay inside the screen.
    private func place(size: NSSize, center: NSPoint, screen: NSScreen?) {
        var frame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                           width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width - 40)
            frame.size.height = min(frame.height, visible.height - 40)
            frame.origin.x = min(max(center.x - frame.width / 2, visible.minX + 20), visible.maxX - 20 - frame.width)
            frame.origin.y = min(max(center.y - frame.height / 2, visible.minY + 20), visible.maxY - 20 - frame.height)
        }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    var isVisible: Bool { panel.isVisible }

    func show(pinned: Bool, filter: Modifiers) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        state.setTarget(app)
        state.filter = filter
        state.search = ""
        state.hoveredKey = nil
        state.pinned = pinned

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            place(size: Self.size(for: state.viewMode), center: NSPoint(x: visible.midX, y: visible.midY), screen: screen)
        }
        if pinned { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        panel.invalidateShadow()
    }

    func pin() {
        guard isVisible else { return }
        state.pinned = true
        panel.makeKey()
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        state.pinned = false
        state.search = ""
    }
}
