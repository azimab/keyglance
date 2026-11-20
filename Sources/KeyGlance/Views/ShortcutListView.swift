import SwiftUI

struct ShortcutListView: View {
    @ObservedObject var state: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = state.listMatches
        VStack(spacing: 0) {
            searchField(count: items.count)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

            if items.isEmpty {
                Spacer()
                Text(state.search.isEmpty ? "No shortcuts with \(state.filter.symbolString)" : "No matches")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if state.search.isEmpty {
                            ForEach(grouped(items), id: \.menu) { group in
                                Section(header: sectionHeader(group.menu)) {
                                    ForEach(group.items) { row($0, showTopMenu: false) }
                                }
                            }
                        } else {
                            ForEach(items) { row($0, showTopMenu: true) }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .onAppear { if state.pinned { searchFocused = true } }
        .onChange(of: state.pinned) { pinned in if pinned { searchFocused = true } }
        .onChange(of: searchFocused) { focused in
            // Clicking into search while holding ⌘ pins the panel so it survives releasing ⌘.
            if focused && !state.pinned { state.requestPin() }
        }
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
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VisualEffectBackground())
    }

    private func row(_ s: Shortcut, showTopMenu: Bool) -> some View {
        let path = showTopMenu ? s.path : Array(s.path.dropFirst())
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 13))
                if !path.isEmpty {
                    Text(path.joined(separator: " › ")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            KeyComboView(shortcut: s)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .opacity(s.enabled ? 1 : 0.45)
    }

    private func grouped(_ items: [Shortcut]) -> [(menu: String, items: [Shortcut])] {
        var order: [String] = []
        var buckets: [String: [Shortcut]] = [:]
        for s in items {
            if buckets[s.topMenu] == nil { order.append(s.topMenu) }
            buckets[s.topMenu, default: []].append(s)
        }
        return order.map { ($0, buckets[$0]!) }
    }
}
