import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: PlayerController
    @AppStorage("search.recent") private var recentRaw = ""
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var isSearching = false
    @State private var errorText: String?

    private var recent: [String] {
        recentRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmed.isEmpty {
                    recentSection
                } else {
                    ForEach(results) { track in
                        Button {
                            remember(query)
                            player.playRadio(from: track)
                        } label: {
                            TrackRow(track: track)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .overlay { overlay }
            .navigationTitle("Cerca")
            .searchable(text: $query, prompt: "Brani e artisti")
            .onSubmit(of: .search) { remember(query) }
            .task(id: query) { await search() }
        }
    }

    @ViewBuilder private var recentSection: some View {
        if !recent.isEmpty {
            Section {
                ForEach(recent, id: \.self) { item in
                    Button { query = item } label: {
                        Label(item, systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(.primary)
                    }
                }
                .onDelete { offsets in
                    var items = recent
                    items.remove(atOffsets: offsets)
                    recentRaw = items.joined(separator: "\n")
                }
            } header: {
                Text("Ricerche recenti")
            }
        }
    }

    @ViewBuilder private var overlay: some View {
        if query.trimmed.isEmpty {
            if recent.isEmpty {
                ContentUnavailableView("Cerca su YouTube Music", systemImage: "magnifyingglass",
                                       description: Text("Scegli un brano: parte una radio di canzoni simili."))
            }
        } else if isSearching && results.isEmpty {
            ProgressView()
        } else if let errorText {
            ContentUnavailableView("Ricerca non riuscita", systemImage: "wifi.exclamationmark",
                                   description: Text(errorText))
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private func search() async {
        let text = query.trimmed
        guard !text.isEmpty else {
            results = []
            errorText = nil
            return
        }
        // Debounce typing.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        do {
            let found = try await InnerTube.shared.searchSongs(text)
            guard !Task.isCancelled else { return }
            results = found
            errorText = nil
        } catch {
            if !Task.isCancelled { errorText = error.localizedDescription }
        }
        if !Task.isCancelled { isSearching = false }
    }

    private func remember(_ text: String) {
        let text = text.trimmed
        guard !text.isEmpty else { return }
        recentRaw = ([text] + recent.filter { $0 != text }).prefix(12).joined(separator: "\n")
    }
}
