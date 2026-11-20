import AppKit
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
    static let size = NSSize(width: 940, height: 460) // header + keyboard (365) + footer, no slack

    private let state: AppState
    private lazy var panel: OverlayPanel = {
        let panel = OverlayPanel(size: Self.size)
        let host = NSHostingView(rootView: OverlayView(state: state))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = [] // never let SwiftUI content resize the panel
        panel.contentView = host
        return panel
    }()

    init(state: AppState) { self.state = state }

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
            panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2,
                                         y: visible.midY - Self.size.height / 2))
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
