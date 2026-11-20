import SwiftUI

struct KeyboardView: View {
    @ObservedObject var state: AppState

    private let unit: CGFloat = 58
    private let gap: CGFloat = 5
    private let keyHeight: CGFloat = 56
    private let fnHeight: CGFloat = 32

    var body: some View {
        let map = state.keyboardMap
        VStack(spacing: gap) {
            row(KeyboardGeometry.functionRow, height: fnHeight, map: map)
            ForEach(Array(KeyboardGeometry.rows.enumerated()), id: \.offset) { _, keys in
                row(keys, height: keyHeight, map: map)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ keys: [KeyDef], height: CGFloat, map: [Int: [Shortcut]]) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                if key.isArrows {
                    arrowCluster(map: map).frame(width: key.width * unit - gap, height: height)
                } else {
                    cap(key.code, map: map, modifier: key.modifier, compact: height < 40)
                        .frame(width: key.width * unit - gap, height: height)
                }
            }
        }
    }

    private func arrowCluster(map: [Int: [Shortcut]]) -> some View {
        let a = KeyboardGeometry.arrowCodes
        return HStack(alignment: .bottom, spacing: gap) {
            cap(a.left, map: map, compact: true).frame(height: keyHeight / 2 - 1)
            VStack(spacing: 2) {
                cap(a.up, map: map, compact: true)
                cap(a.down, map: map, compact: true)
            }
            cap(a.right, map: map, compact: true).frame(height: keyHeight / 2 - 1)
        }
    }

    private func cap(_ code: Int, map: [Int: [Shortcut]], modifier: Modifiers? = nil, compact: Bool) -> some View {
        KeyCapView(label: state.layout.label(for: code),
                   shortcuts: map[code] ?? [],
                   modifier: modifier,
                   modifierActive: modifier.map { state.filter.contains($0) } ?? false,
                   compact: compact)
            .onHover { inside in
                if inside { state.hoveredKey = code } else if state.hoveredKey == code { state.hoveredKey = nil }
            }
            .onTapGesture { if let modifier { state.toggleFilter(modifier) } }
    }
}

struct KeyCapView: View {
    let label: String
    let shortcuts: [Shortcut]
    var modifier: Modifiers? = nil
    var modifierActive = false
    var compact = false

    var body: some View {
        let has = !shortcuts.isEmpty
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(modifierActive ? Color.white : (has ? Color.primary : Color.secondary))
                .lineLimit(1)
            if let first = shortcuts.first, !compact {
                Text(first.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(first.enabled ? 0.9 : 0.45))
                    .lineLimit(shortcuts.count > 1 ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                if shortcuts.count > 1 {
                    Text("+\(shortcuts.count - 1) more").font(.system(size: 8.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, compact ? 2 : 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact && !has ? .center : .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill(has)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(has ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.1), lineWidth: 1))
        .contentShape(Rectangle())
        .help(tooltip)
    }

    private func fill(_ has: Bool) -> Color {
        if modifierActive { return Color.accentColor.opacity(0.85) }
        if has { return Color.accentColor.opacity(0.22) }
        return Color.primary.opacity(modifier != nil ? 0.09 : 0.05)
    }

    private var tooltip: String {
        if let modifier { return "Click to toggle \(modifier.symbolString)" }
        return shortcuts.map { "\($0.display)  \(($0.path + [$0.title]).joined(separator: " › "))" }
            .joined(separator: "\n")
    }
}
