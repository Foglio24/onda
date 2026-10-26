import SwiftUI

struct SearchView: View {
    private var player: PlayerController { .shared }
    @EnvironmentObject private var router: AppRouter
    @AppStorage(Preferences.recentSearches) private var recentRaw = ""
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var catalog = CatalogResults()
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
                    catalogSections
                    if !results.isEmpty {
                        Section {
                            ForEach(results) { track in
                                TrackRow(track: track) {
                                    remember(query)
                                    player.playRadio(from: track)
                                }
                                .listRowBackground(Color.clear)
                            }
                        } header: {
                            if !catalog.isEmpty { Text("Brani") }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { AmbientBackground() }
            .overlay { overlay }
            .navigationTitle("Cerca")
            .searchable(text: $query, prompt: "Brani, artisti e album")
            .onSubmit(of: .search) { remember(query) }
            .task(id: query) { await search() }
            .onAppear(perform: takePendingSearch)
            .onChange(of: router.pendingSearch) { _, _ in takePendingSearch() }
        }
    }

    /// The top result, then artists and albums as horizontal rows of cards.
    @ViewBuilder private var catalogSections: some View {
        if let top = catalog.top {
            Section {
                MusicLink(item: top) { MusicItemRow(item: top) }
                    .simultaneousGesture(TapGesture().onEnded { remember(query) })
                    .listRowBackground(Color.clear)
            } header: {
                Text("Risultato migliore")
            }
        }
        if !catalog.artists.isEmpty {
            cardSection("Artisti", items: catalog.artists, size: 104)
        }
        if !catalog.albums.isEmpty {
            cardSection("Album", items: catalog.albums, size: 130)
        }
    }

    private func cardSection(_ title: LocalizedStringKey, items: [MusicItem], size: CGFloat) -> some View {
        Section {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        MusicLink(item: item) { MusicItemCard(item: item, size: size) }
                            .simultaneousGesture(TapGesture().onEnded { remember(query) })
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 10, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text(title)
        }
    }

    private func takePendingSearch() {
        guard let pending = router.pendingSearch else { return }
        router.pendingSearch = nil
        query = pending
    }

    @ViewBuilder private var recentSection: some View {
        if !recent.isEmpty {
            Section {
                ForEach(recent, id: \.self) { item in
                    Button { query = item } label: {
                        Label(item, systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(.primary)
                    }
                    .listRowBackground(Color.clear)
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
        } else if isSearching && results.isEmpty && catalog.isEmpty {
            ProgressView()
        } else if let errorText {
            ContentUnavailableView("Ricerca non riuscita", systemImage: "wifi.exclamationmark",
                                   description: Text(errorText))
        } else if results.isEmpty && catalog.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    private func search() async {
        let text = query.trimmed
        guard !text.isEmpty else {
            results = []
            catalog = CatalogResults()
            errorText = nil
            return
        }
        // Debounce typing.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        do {
            // Artists and albums are a bonus: the songs still show if that search fails.
            async let foundCatalog = InnerTube.shared.searchCatalog(text)
            let found = try await InnerTube.shared.searchSongs(text)
            let foundArtistsAndAlbums = (try? await foundCatalog) ?? CatalogResults()
            guard !Task.isCancelled else { return }
            results = found
            catalog = foundArtistsAndAlbums
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
