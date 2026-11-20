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
                                        .font(.system(size: page.metrics.font - 1, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, ColumnPage.rowPadding)
                                        .frame(height: page.metrics.row)
                                }
                            }
                            .frame(width: page.columnWidth, alignment: .leading)
                        }
                    }
                    // Columns have a fixed width and the block is centered, so the layout looks the
                    // same whether there are 5 shortcuts or 150.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                .font(.system(size: 14))
                .focused($searchFocused)
            if !state.search.isEmpty {
                Button { state.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
    }

    @ViewBuilder
    private func entryView(_ entry: ColumnPage.Entry, metrics: ColumnPage.Metrics, showTopMenu: Bool) -> some View {
        let appName = state.targetApp?.localizedName
        switch entry {
        case let .header(title):
            HStack(spacing: 7) {
                Image(systemName: MenuIcon.symbol(for: title, appName: appName))
                    .font(.system(size: metrics.headerFont - 1, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: metrics.headerFont + 4)
                Text(title)
                    .font(.system(size: metrics.headerFont, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .lineLimit(1)
            .padding(.horizontal, ColumnPage.rowPadding - 2)
            .padding(.bottom, metrics.header * 0.16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: metrics.header, alignment: .bottom)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.bottom, 2)
            }
        case let .item(s):
            // The top menu is shown by the header (grouped) or the leading icon (search); only submenus go here.
            let path = Array(s.path.dropFirst())
            HStack(spacing: 8) {
                if showTopMenu {
                    Image(systemName: MenuIcon.symbol(for: s.topMenu, appName: appName))
                        .font(.system(size: metrics.font - 2))
                        .foregroundStyle(.secondary)
                        .frame(width: metrics.font + 2)
                }
                Text(s.title)
                    .font(.system(size: metrics.font))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !path.isEmpty {
                    Text(path.joined(separator: " › "))
                        .font(.system(size: metrics.font - 2))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 8)
                CompactComboView(shortcut: s, fontSize: metrics.font - 0.5, height: metrics.row - 8)
            }
            .padding(.horizontal, ColumnPage.rowPadding)
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
        return order.flatMap { menu in [.header(menu)] + buckets[menu]!.map { .item($0) } }
    }
}

/// SF Symbol for a top-level menu name; falls back to a generic menu glyph.
enum MenuIcon {
    static func symbol(for menu: String, appName: String?) -> String {
        if let appName, menu == appName { return "app" }
        let key = menu.lowercased()
        for (names, symbol) in table where names.contains(key) { return symbol }
        return "filemenu.and.selection"
    }

    private static let table: [([String], String)] = [
        (["file", "shell"], "doc"),
        (["edit"], "pencil"),
        (["view"], "eye"),
        (["window", "windows"], "macwindow"),
        (["help"], "questionmark.circle"),
        (["history"], "clock.arrow.circlepath"),
        (["bookmarks", "favorites"], "bookmark"),
        (["develop", "developer", "debug"], "hammer"),
        (["format"], "textformat"),
        (["text", "font"], "textformat.size"),
        (["insert"], "plus.square"),
        (["tools"], "wrench.and.screwdriver"),
        (["go", "navigate", "navigation"], "arrow.turn.up.right"),
        (["find", "search"], "magnifyingglass"),
        (["selection", "select"], "selection.pin.in.out"),
        (["image", "photo", "photos"], "photo"),
        (["table"], "tablecells"),
        (["arrange", "object", "layer", "layers"], "square.3.layers.3d"),
        (["product", "build"], "shippingbox"),
        (["editor", "code"], "chevron.left.forwardslash.chevron.right"),
        (["run", "playback", "controls", "media"], "playpause"),
        (["terminal", "session"], "terminal"),
        (["tab", "tabs"], "square.on.square"),
        (["song", "music"], "music.note"),
        (["mailbox"], "tray"),
        (["message", "mail"], "envelope"),
        (["conversation", "chat"], "bubble.left"),
        (["account", "profile", "profiles", "people"], "person.crop.circle"),
        (["slide", "slides", "play"], "play.rectangle"),
        (["filter", "filters"], "camera.filters"),
        (["extensions", "plugins"], "puzzlepiece"),
        (["git", "source control"], "arrow.triangle.branch"),
        (["markup", "annotate"], "pencil.tip.crop.circle"),
        (["share"], "square.and.arrow.up"),
        (["calendar"], "calendar"),
        (["sort"], "arrow.up.arrow.down"),
        (["data"], "cylinder"),
        (["sketch", "draw", "shape"], "scribble"),
    ]
}

/// Packs entries column-major into the fewest columns that keep rows comfortable, shrinking rows
/// (down to a floor) when needed so the whole set fits on one page.
struct ColumnPage {
    enum Entry {
        case header(String)
        case item(Shortcut)
    }

    struct Metrics {
        let row: CGFloat
        var header: CGFloat { row * 1.5 }
        var font: CGFloat { min(14, max(10.5, row * 0.5)) }
        var headerFont: CGFloat { font + 1.5 }
    }

    static let gutter: CGFloat = 28
    static let inset: CGFloat = 22
    static let vInset: CGFloat = 12
    static let rowPadding: CGFloat = 8
    static let comfortableRow: CGFloat = 30
    static let minRow: CGFloat = 18
    static let minColumnWidth: CGFloat = 270
    static let maxColumnWidth: CGFloat = 340

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
        // Width comes from the maximum column count, not the used count, so it never changes with content.
        let n = CGFloat(maxColumns)
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

    /// Column-major fill that keeps each menu (header + its items) together in one column, moving
    /// the whole menu to the next column when it doesn't fit. Only a menu taller than an entire column
    /// is split: it starts at the top of a fresh column and flows on into the next, with no repeated header.
    private static func pack(_ entries: [Entry], capacity: Int) -> (columns: [[Entry]], units: [Int]) {
        var sections: [[Entry]] = []
        for e in entries {
            if case .header = e {
                sections.append([e])
            } else if let first = sections.last?.first, case .header = first {
                sections[sections.count - 1].append(e)
            } else {
                sections.append([e]) // ungrouped (search results): each row flows on its own
            }
        }

        var cols: [[Entry]] = [[]]
        var used = [0]
        func newColumn() { cols.append([]); used.append(0) }
        func add(_ e: Entry) { cols[cols.count - 1].append(e); used[used.count - 1] += units(e) }

        for section in sections {
            let size = section.reduce(0) { $0 + units($1) }
            if size <= capacity - used[used.count - 1] {
                section.forEach(add)
            } else if size <= capacity {
                newColumn()
                section.forEach(add)
            } else {
                if !cols[cols.count - 1].isEmpty { newColumn() }
                for e in section {
                    if used[used.count - 1] + units(e) > capacity { newColumn() }
                    add(e)
                }
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
        HStack(spacing: 1) {
            Text(shortcut.displayModifiers.symbolString)
                .foregroundStyle(.secondary)
            Text(shortcut.keyLabel)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
            .font(.system(size: fontSize, weight: .medium, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(minHeight: max(0, height))
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
    }
}
