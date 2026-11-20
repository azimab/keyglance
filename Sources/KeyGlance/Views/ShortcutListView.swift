import SwiftUI

/// Every matching shortcut on one page: menus flow top-to-bottom through as many columns as needed,
/// and rows shrink until everything fits. No scrolling. Search appears only once the panel is pinned.
struct ShortcutListView: View {
    @ObservedObject var state: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = state.listMatches
        let searching = state.pinned && !state.search.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(spacing: 0) {
            if state.pinned {
                searchField(count: items.count)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
            }

            if items.isEmpty {
                Spacer()
                Text(searching ? "No matches" : "No shortcuts with \(state.filter.symbolString)")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                GeometryReader { geo in
                    let page = ColumnPage(entries: Self.entries(items, grouped: !searching), size: geo.size)
                    HStack(alignment: .top, spacing: ColumnPage.gutter) {
                        ForEach(page.columns.indices, id: \.self) { ci in
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(page.columns[ci].indices, id: \.self) { ri in
                                    entryView(page.columns[ci][ri], metrics: page.metrics, showTopMenu: searching)
                                }
                                if ci == page.columns.count - 1, page.overflow > 0 {
                                    Text("+\(page.overflow) more — add modifiers\(state.pinned ? " or search" : " or pin to search")")
                                        .font(.system(size: page.metrics.font, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(height: page.metrics.row)
                                }
                            }
                            .frame(width: page.columnWidth, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, ColumnPage.inset)
                    .padding(.vertical, ColumnPage.vInset)
                }
            }
        }
        .onAppear { if state.pinned { searchFocused = true } }
        .onChange(of: state.pinned) { pinned in if pinned { searchFocused = true } }
    }

    private func searchField(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search \(count) shortcuts", text: $state.search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !state.search.isEmpty {
                Button { state.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
    }

    @ViewBuilder
    private func entryView(_ entry: ColumnPage.Entry, metrics: ColumnPage.Metrics, showTopMenu: Bool) -> some View {
        switch entry {
        case let .header(title, continued):
            Text(title.uppercased() + (continued ? " (cont.)" : ""))
                .font(.system(size: max(8, metrics.font - 2.5), weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: metrics.header, alignment: .bottomLeading)
                .padding(.bottom, metrics.header * 0.12)
        case let .item(s):
            let path = showTopMenu ? s.path : Array(s.path.dropFirst())
            HStack(spacing: 6) {
                Text(s.title)
                    .font(.system(size: metrics.font))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !path.isEmpty {
                    Text(path.joined(separator: " › "))
                        .font(.system(size: max(8, metrics.font - 2)))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 4)
                CompactComboView(shortcut: s, fontSize: metrics.font - 0.5, height: metrics.row - 3)
            }
            .frame(height: metrics.row)
            .opacity(s.enabled ? 1 : 0.45)
            .help((s.path + [s.title]).joined(separator: " › "))
        }
    }

    static func entries(_ items: [Shortcut], grouped: Bool) -> [ColumnPage.Entry] {
        guard grouped else { return items.map { .item($0) } }
        var order: [String] = []
        var buckets: [String: [Shortcut]] = [:]
        for s in items {
            if buckets[s.topMenu] == nil { order.append(s.topMenu) }
            buckets[s.topMenu, default: []].append(s)
        }
        return order.flatMap { menu in [.header(menu, continued: false)] + buckets[menu]!.map { .item($0) } }
    }
}

/// Packs entries column-major into the fewest columns that keep rows comfortable, shrinking rows
/// (down to a floor) when needed so the whole set fits on one page.
struct ColumnPage {
    enum Entry {
        case header(String, continued: Bool)
        case item(Shortcut)
    }

    struct Metrics {
        let row: CGFloat
        var header: CGFloat { row * 1.5 }
        var font: CGFloat { min(13, max(8.5, row * 0.58)) }
    }

    static let gutter: CGFloat = 22
    static let inset: CGFloat = 20
    static let vInset: CGFloat = 8
    static let comfortableRow: CGFloat = 22
    static let minRow: CGFloat = 10
    static let minColumnWidth: CGFloat = 160
    static let maxColumnWidth: CGFloat = 420

    // Packing works in half-row units so headers (1.5 rows) stay integral.
    private static let itemUnits = 2, headerUnits = 3

    let columns: [[Entry]]
    let metrics: Metrics
    let columnWidth: CGFloat
    let overflow: Int

    init(entries: [Entry], size: CGSize) {
        let width = size.width - Self.inset * 2
        let height = size.height - Self.vInset * 2
        let maxColumns = max(1, Int((width + Self.gutter) / (Self.minColumnWidth + Self.gutter)))

        var chosen: (cols: [[Entry]], row: CGFloat)?
        for c in 1...maxColumns {
            let capacity = Self.minimalCapacity(entries, columns: c)
            let row = min(Self.comfortableRow, height / (CGFloat(capacity) / 2))
            if row >= Self.minRow, chosen == nil || row > chosen!.row + 0.5 {
                chosen = (Self.pack(entries, capacity: capacity).columns, row)
            }
            if row >= Self.comfortableRow { break }
        }

        if let chosen {
            columns = chosen.cols
            metrics = Metrics(row: chosen.row)
            overflow = 0
        } else {
            // Too many to fit even at the smallest size: fill every column at minRow, keep one slot for "+N more".
            let capacity = Int(height / Self.minRow) * 2
            let packed = Self.pack(entries, capacity: capacity)
            var cols = Array(packed.columns.prefix(maxColumns))
            var shown = cols.flatMap { $0 }.filter { if case .item = $0 { return true } else { return false } }.count
            if var last = cols.popLast() {
                var used = last.reduce(0) { $0 + Self.units($1) }
                while used + Self.itemUnits > capacity, let removed = last.popLast() {
                    used -= Self.units(removed)
                    if case .item = removed { shown -= 1 }
                }
                if case .header = last.last { last.removeLast() }
                cols.append(last)
            }
            columns = cols
            metrics = Metrics(row: Self.minRow)
            overflow = entries.filter { if case .item = $0 { return true } else { return false } }.count - shown
        }
        let n = CGFloat(max(columns.count, 1))
        columnWidth = min(Self.maxColumnWidth, max(0, (width - Self.gutter * (n - 1)) / n))
    }

    private static func units(_ e: Entry) -> Int {
        if case .header = e { return headerUnits } else { return itemUnits }
    }

    /// Smallest per-column capacity (in half-rows) that fits all entries in `columns` columns.
    private static func minimalCapacity(_ entries: [Entry], columns: Int) -> Int {
        let total = entries.reduce(0) { $0 + units($1) }
        var k = max(headerUnits + itemUnits, Int((Double(total) / Double(columns)).rounded(.up)))
        while pack(entries, capacity: k).columns.count > columns { k += 1 }
        return k
    }

    /// Greedy column-major fill. Never strands a header at a column bottom; repeats a "(cont.)"
    /// header when a menu's items spill into the next column.
    private static func pack(_ entries: [Entry], capacity: Int) -> (columns: [[Entry]], units: [Int]) {
        var cols: [[Entry]] = [[]]
        var used = [0]
        var currentMenu: String?
        for e in entries {
            switch e {
            case let .header(title, _):
                currentMenu = title
                if !cols[cols.count - 1].isEmpty, used[used.count - 1] + headerUnits + itemUnits > capacity {
                    cols.append([]); used.append(0)
                }
                cols[cols.count - 1].append(e); used[used.count - 1] += headerUnits
            case .item:
                if !cols[cols.count - 1].isEmpty, used[used.count - 1] + itemUnits > capacity {
                    cols.append([]); used.append(0)
                    if let menu = currentMenu, capacity >= headerUnits + itemUnits {
                        cols[cols.count - 1].append(.header(menu, continued: true))
                        used[used.count - 1] += headerUnits
                    }
                }
                cols[cols.count - 1].append(e); used[used.count - 1] += itemUnits
            }
        }
        return (cols, used)
    }
}

/// Single-keycap combo (⇧⌘N) that scales with the row.
struct CompactComboView: View {
    let shortcut: Shortcut
    let fontSize: CGFloat
    let height: CGFloat

    var body: some View {
        Text(shortcut.displayModifiers.symbolString + shortcut.keyLabel)
            .font(.system(size: fontSize, weight: .medium, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(minHeight: max(0, height))
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }
}
