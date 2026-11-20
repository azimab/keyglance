import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(state: state)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider().opacity(0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            FooterView(state: state)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder private var content: some View {
        if !state.axTrusted {
            PermissionView(state: state)
        } else if state.isLoading && state.shortcuts.isEmpty {
            ProgressView("Reading menus…").controlSize(.small)
        } else if state.viewMode == .keyboard {
            KeyboardView(state: state)
        } else {
            ShortcutListView(state: state)
        }
    }
}

struct HeaderView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            if let icon = state.targetApp?.icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(state.targetApp?.localizedName ?? "—").font(.system(size: 14, weight: .semibold))
                Text("\(state.baseShortcuts.count) shortcuts").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()

            HStack(spacing: 4) {
                ForEach(Modifiers.ordered, id: \.symbol) { entry in
                    let on = state.filter.contains(entry.mod)
                    Button { state.toggleFilter(entry.mod) } label: {
                        Text(entry.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 26, height: 22)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
                            .foregroundStyle(on ? Color.white : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("\(entry.name): \(on ? "on" : "off") — click to toggle")
                }
            }

            Picker("", selection: $state.viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)

            Button { state.pinned ? state.requestClose() : state.requestPin() } label: {
                Image(systemName: state.pinned ? "xmark.circle.fill" : "pin")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(state.pinned ? "Close (esc)" : "Keep open after releasing ⌘")
        }
    }
}

struct FooterView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if state.axTrusted, !state.isLoading, state.shortcuts.count < 8 {
                Label("Few menu shortcuts found — Electron/web apps may not expose full menus",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
            }
            if state.hideUniversal && state.hiddenUniversalCount > 0 {
                Button("\(state.hiddenUniversalCount) universal hidden · show") { state.hideUniversal = false }
                    .buttonStyle(.link).font(.system(size: 11))
            } else if !state.hideUniversal {
                Button("hide universal") { state.hideUniversal = true }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
    }

    private var hint: String {
        if let code = state.hoveredKey, let items = state.keyboardMap[code], !items.isEmpty {
            return items.map { "\($0.display)  \(($0.path + [$0.title]).joined(separator: " › "))" }
                .joined(separator: "   ·   ")
        }
        if state.pinned { return "esc to close · click modifiers to filter" }
        return "Add ⇧ ⌥ ⌃ to narrow · release ⌘ to dismiss · 📌 to keep open"
    }
}

struct PermissionView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("KeyGlance needs Accessibility access").font(.headline)
            Text("It reads the frontmost app's menu bar to find its shortcuts. Nothing leaves your Mac.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Open Accessibility Settings") { state.openAccessibilitySettings() }
                .controlSize(.large)
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active // stay vibrant even though the panel is never "active"
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Renders a combo like ⇧⌘N as individual keycaps.
struct KeyComboView: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(spacing: 3) {
            ForEach(shortcut.displayModifiers.symbols + [shortcut.keyLabel], id: \.self) { part in
                Text(part)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.09)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
            }
        }
    }
}
