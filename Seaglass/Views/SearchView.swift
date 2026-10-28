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
    @State private var path: [MusicPage] = []
    @State private var showAllSongs = false

    /// Songs shown before "Mostra tutti i brani", so playlists and artists stay in sight.
    private static let songsPreview = 6

    private var recent: [String] {
        recentRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.trimmed.isEmpty {
                    recentSection
                } else {
                    resultSections
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { AmbientBackground() }
            .overlay { overlay }
            .navigationTitle("Cerca")
            .navigationDestination(for: MusicPage.self) { MusicPageView(page: $0) }
            .searchable(text: $query, prompt: "Brani, playlist e artisti")
            .onSubmit(of: .search) { remember(query) }
            .task(id: query) { await search() }
            .onAppear(perform: takePendingSearch)
            .onChange(of: router.pendingSearch) { _, _ in takePendingSearch() }
        }
    }

    /// Songs first, then playlists, artists and albums; an artist comes before everything when the
    /// search is their name.
    @ViewBuilder private var resultSections: some View {
        let layout = SearchLayout(query: query, songs: results, catalog: catalog)
        if let artist = layout.namedArtist {
            Section {
                Button { open(artist) } label: { MusicItemRow(item: artist) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
            } header: {
                Text("Artista")
            }
        }
        if !layout.songs.isEmpty {
            let shown = showAllSongs ? layout.songs : Array(layout.songs.prefix(Self.songsPreview))
            Section {
                ForEach(shown) { track in
                    TrackRow(track: track) {
                        remember(query)
                        player.playRadio(from: track)
                    }
                    .listRowBackground(Color.clear)
                }
                if shown.count < layout.songs.count {
                    Button {
                        withAnimation { showAllSongs = true }
                    } label: {
                        Label("Mostra tutti i brani (\(layout.songs.count))", systemImage: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                    }
                    .listRowBackground(Color.clear)
                }
            } header: {
                if !catalog.isEmpty { Text("Brani") }
            }
        }
        if !layout.playlists.isEmpty {
            cardSection("Playlist", items: layout.playlists, size: 130)
        }
        if !layout.artists.isEmpty {
            cardSection("Artisti", items: layout.artists, size: 104)
        }
        if !layout.albums.isEmpty {
            cardSection("Album", items: layout.albums, size: 130)
        }
    }

    /// A horizontal row of cards. Buttons that push the page, not links: links inside a list row's
    /// scroll view didn't always open.
    private func cardSection(_ title: LocalizedStringKey, items: [MusicItem], size: CGFloat) -> some View {
        Section {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        Button { open(item) } label: { MusicItemCard(item: item, size: size) }
                            .buttonStyle(.plain)
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

    private func open(_ item: MusicItem) {
        remember(query)
        if case .song(let track) = item.kind {
            player.playRadio(from: track)
        } else if let page = MusicPage(item) {
            path.append(page)
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
            // Playlists, artists and albums are a bonus: the songs still show if those searches fail.
            async let foundCatalog = InnerTube.shared.searchCatalog(text)
            async let foundPlaylists = InnerTube.shared.searchPlaylists(text)
            let found = try await InnerTube.shared.searchSongs(text)
            var others = (try? await foundCatalog) ?? CatalogResults()
            let playlists = (try? await foundPlaylists) ?? []
            let known = Set(playlists.map(\.id))
            others.playlists = playlists + others.playlists.filter { !known.contains($0.id) }
            guard !Task.isCancelled else { return }
            results = found
            catalog = others
            showAllSongs = false
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

/// What the search shows, in order. YouTube Music's top result joins its own kind's row.
private struct SearchLayout {
    let namedArtist: MusicItem?
    let songs: [Track]
    let playlists: [MusicItem]
    let artists: [MusicItem]
    let albums: [MusicItem]

    init(query: String, songs: [Track], catalog: CatalogResults) {
        let named = catalog.artist(named: query)
        namedArtist = named
        self.songs = songs
        func withTop(_ items: [MusicItem], _ belongs: (MusicItem) -> Bool) -> [MusicItem] {
            var items = items
            if let top = catalog.top, belongs(top), !items.contains(where: { $0.id == top.id }) {
                items.insert(top, at: 0)
            }
            return items.filter { $0.id != named?.id }
        }
        playlists = withTop(catalog.playlists) { $0.kind == .playlist }
        artists = withTop(catalog.artists) { $0.isArtist }
        albums = withTop(catalog.albums) { $0.kind == .album }
    }
}
