import SwiftUI

struct SearchView: View {
    @Environment(\.interfaceStyle) private var style
    private var player: PlayerController { .shared }
    @EnvironmentObject private var router: AppRouter
    @AppStorage(Preferences.recentSearches) private var recentRaw = ""
    @AppStorage(Preferences.recentSearchItems) private var recentData = Data()
    @State private var query = ""
    @State private var results: [Track] = []
    /// The user's own songs that match, shown at once (no network) above YouTube Music's.
    @State private var localResults: [Track] = []
    @State private var catalog = CatalogResults()
    @State private var isSearching = false
    /// The text the results shown are for (they stay while the next search runs).
    @State private var searchedText = ""
    @State private var errorText: String?
    @State private var path: [MusicPage] = []
    @State private var showAllSongs = false
    /// Classic search field focused: shows recent searches over the browse tiles.
    @FocusState private var classicSearchFocused: Bool
    /// The classic search's recent searches are open: from a tap in the field until Annulla, as the
    /// common streaming apps. Not the field's focus, which a drag on the list takes away with the
    /// keyboard, and with it the list being swiped.
    @State private var showsRecent = false

    /// Songs shown before "Mostra tutti i brani", so playlists and artists stay in sight.
    private static let songsPreview = 6
    /// The user's own songs shown (the Library page has them all).
    private static let localPreview = 8

    /// The search's history, newest first: what was picked, with its cover, and searches sent. Until
    /// this version has saved one, the searches older versions kept.
    private var recent: [RecentSearch] {
        recentData.isEmpty ? recentRaw.split(separator: "\n").map { RecentSearch(query: String($0)) } : RecentSearch.decode(recentData)
    }

    private static let recentLimit = 20
    /// The classic style, on the iPhone, the iPad and the Mac alike.
    private var classicPhone: Bool { style == .classic }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if classicPhone {
                    classicBody
                } else {
                    seaglassBody
                }
            }
            .background { AmbientBackground() }
            .navigationDestination(for: MusicPage.self) { MusicPageView(page: $0) }
            .task(id: query) { await search() }
            .onAppear(perform: takePendingSearch)
            .onChange(of: router.pendingSearch) { _, _ in takePendingSearch() }
        }
    }

    private var seaglassBody: some View {
        List {
            Group {
                if query.trimmed.isEmpty {
                    recentSection
                } else {
                    resultSections
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay { overlay }
        .navigationTitle("Cerca")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { RecognitionButton() }
        }
        .searchable(text: $query, prompt: "Brani, playlist e artisti")
        .onSubmit(of: .search) { remember(query) }
    }

    /// Classic: white search field, category tiles, browse-all genres, recent when typing or focused.
    private var classicBody: some View {
        VStack(spacing: 0) {
            classicSearchChrome
            List {
                Group {
                    if query.trimmed.isEmpty {
                        // Focused: recent searches (as the common streaming apps). Idle: browse tiles.
                        if showsRecent {
                            recentSection
                        } else {
                            classicCategorySection
                            browseSection
                        }
                    } else {
                        resultSections
                    }
                }
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay { overlay }
        }
        .classicHeader {
            ClassicHeader(title: "Cerca") { RecognitionButton() }
        }
    }

    private var classicSearchChrome: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.black.opacity(0.7))
                TextField("Cosa vuoi ascoltare?", text: $query)
                    .focused($classicSearchFocused)
                    .onChange(of: classicSearchFocused) { _, focused in
                        if focused { showsRecent = true }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .foregroundStyle(.black)
                    .tint(ClassicPalette.accent)
                    .onSubmit { remember(query) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(ClassicPalette.field, in: .rect(cornerRadius: 8))
            .environment(\.colorScheme, .light)
            if showsRecent || !query.isEmpty {
                Button("Annulla") {
                    query = ""
                    classicSearchFocused = false
                    showsRecent = false
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(ClassicPalette.primaryText)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// Musica / Podcast as the first browse row (tapping starts that search).
    private var classicCategorySection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(BrowseTile.categories) { tile in
                    Button { query = tile.query } label: { BrowseTileView(tile: tile) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
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
        if !localResults.isEmpty {
            Section {
                ForEach(Array(localResults.prefix(Self.localPreview).enumerated()), id: \.element.id) { position, track in
                    TrackRow(track: track) {
                        remember(RecentSearch(track: track))
                        player.play(localResults, startAt: position, source: String(localized: "File locali"))
                    }
                    .listRowBackground(Color.clear)
                }
            } header: {
                Text("Sul dispositivo")
            }
        }
        if !layout.songs.isEmpty {
            let shown = showAllSongs ? layout.songs : Array(layout.songs.prefix(Self.songsPreview))
            Section {
                ForEach(shown) { track in
                    TrackRow(track: track) {
                        remember(RecentSearch(track: track))
                        playFromSearch(track)
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
        if !layout.podcasts.isEmpty {
            cardSection("Podcast", items: layout.podcasts, size: 130)
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

    /// A song picked here: in the classic style it plays without losing the queue (see `playNow`);
    /// in Seaglass's it starts its radio, as before.
    private func playFromSearch(_ track: Track) {
        if classicPhone { player.playNow(track) } else { player.playRadio(from: track) }
    }

    private func open(_ item: MusicItem) {
        remember(RecentSearch(item: item))
        if case .song(let track) = item.kind {
            playFromSearch(track)
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
        let entries = recent
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    recentRow(entry)
                }
            } header: {
                Text("Ricerche recenti")
            }
        }
    }

    /// A song of the history is a song row like any other: swiped right it joins the queue, swiped left
    /// it goes to the favourites or leaves the history, held it opens its menu. The rest (a search, an
    /// artist, an album, a playlist) opens when tapped and leaves the history by a swipe left or held.
    @ViewBuilder private func recentRow(_ entry: RecentSearch) -> some View {
        if classicPhone {
            Button { openRecent(entry) } label: {
                RecentSearchRow(entry: entry, trailing: AnyView(
                    HStack(spacing: 14) {
                        if entry.track.map({ Library.shared.isLiked($0) }) == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(ClassicPalette.accent)
                        }
                        Button { forget(entry) } label: {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(ClassicPalette.secondaryText)
                                .frame(width: 28, height: 28)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                ))
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        } else if let track = entry.track {
            TrackRow(track: track, remove: { forget(entry) }) {
                openRecent(entry)
            }
                .listRowBackground(Color.clear)
        } else {
            Button { openRecent(entry) } label: { RecentSearchRow(entry: entry) }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { forget(entry) } label: {
                        Label("Rimuovi", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) { forget(entry) } label: {
                        Label("Rimuovi dalla cronologia", systemImage: "trash")
                    }
                }
        }
    }

    private func forget(_ entry: RecentSearch) {
        save(recent.filter { $0.id != entry.id })
    }

    /// A search sent searches again; a song plays (see `playFromSearch`), anything else opens its page.
    private func openRecent(_ entry: RecentSearch) {
        if let track = entry.track {
            remember(entry)
            playFromSearch(track)
        } else if let item = entry.item, let page = MusicPage(item) {
            remember(entry)
            path.append(page)
        } else {
            query = entry.title
        }
    }

    /// The classic style's "browse all": genres and moods as coloured tiles, two by two; one searches it.
    private var browseSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(BrowseTile.all) { tile in
                    Button {
                        // Not kept in the history: the search is the tile's, not one the user typed.
                        query = tile.query
                    } label: {
                        BrowseTileView(tile: tile)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 16, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text("Sfoglia tutto")
        }
    }

    @ViewBuilder private var overlay: some View {
        if query.trimmed.isEmpty {
            if recent.isEmpty, style != .classic {
                ContentUnavailableView("Cerca su YouTube Music", systemImage: "magnifyingglass",
                                       description: Text("Scegli un brano: parte una radio di canzoni simili."))
            }
        } else if let errorText, searchedText == query.trimmed, localResults.isEmpty {
            ContentUnavailableView("Ricerca non riuscita", systemImage: "wifi.exclamationmark",
                                   description: Text(errorText))
        } else if results.isEmpty && catalog.isEmpty && localResults.isEmpty {
            // Nothing found only once this very text has been searched; until then, it is on its way.
            if isSearching || searchedText != query.trimmed {
                ProgressView()
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    /// Searches as the text is typed, without waiting for the return key: a short pause between
    /// keys, then the songs as soon as they come (the results before stay until then), then the
    /// playlists, artists and albums.
    private func search() async {
        let text = query.trimmed
        // The user's own songs need no network: they show with the first letters.
        localResults = text.isEmpty ? [] : LocalMusic.shared.search(text)
        guard !text.isEmpty else {
            results = []
            catalog = CatalogResults()
            searchedText = ""
            errorText = nil
            isSearching = false
            return
        }
        // Debounce typing: long enough not to search at every key, short enough to feel immediate.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        isSearching = true
        // Playlists, artists and albums are a bonus: the songs still show if those searches fail.
        async let foundCatalog = InnerTube.shared.searchCatalog(text)
        async let foundPlaylists = InnerTube.shared.searchPlaylists(text)
        do {
            let found = try await InnerTube.shared.searchSongs(text)
            guard !Task.isCancelled else { return }
            if searchedText != text { catalog = CatalogResults() }
            results = found
            searchedText = text
            showAllSongs = false
            errorText = nil
        } catch {
            guard !Task.isCancelled else { return }
            searchedText = text
            errorText = error.localizedDescription
        }
        var others = (try? await foundCatalog) ?? CatalogResults()
        let playlists = (try? await foundPlaylists) ?? []
        guard !Task.isCancelled else { return }
        let known = Set(playlists.map(\.id))
        others.playlists = playlists + others.playlists.filter { !known.contains($0.id) }
        catalog = others
        isSearching = false
    }

    private func remember(_ text: String) {
        let text = text.trimmed
        guard !text.isEmpty else { return }
        remember(RecentSearch(query: text))
    }

    private func remember(_ entry: RecentSearch) {
        save([entry] + recent.filter { $0.id != entry.id })
    }

    private func save(_ entries: [RecentSearch]) {
        let kept = Array(entries.prefix(Self.recentLimit))
        recentData = (try? JSONEncoder().encode(kept)) ?? Data()
        // Older versions read the searches sent from here.
        recentRaw = kept.filter { $0.kind == .query }.map(\.title).joined(separator: "\n")
    }
}

/// One entry of the search's history: what was picked from the results (a song, an artist, an
/// album, a playlist or a podcast, with its cover), or a search sent without picking anything.
struct RecentSearch: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case query, song, artist, album, playlist, podcast
    }

    var kind: Kind
    /// The text searched, the song's video ID or the page's browse ID.
    var key: String
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var track: Track?

    var id: String { "\(kind.rawValue):\(key)" }

    private init(kind: Kind, key: String, title: String, subtitle: String, artworkURL: URL?, track: Track?) {
        self.kind = kind
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.track = track
    }

    init(query: String) {
        self.init(kind: .query, key: query, title: query, subtitle: "", artworkURL: nil, track: nil)
    }

    init(track: Track) {
        self.init(kind: .song, key: track.id, title: track.title, subtitle: track.artist, artworkURL: track.artworkURL, track: track)
    }

    init(item: MusicItem) {
        let kind: Kind
        switch item.kind {
        case .song(let track):
            self.init(track: track)
            return
        case .artist: kind = .artist
        case .album: kind = .album
        case .playlist: kind = .playlist
        case .podcast: kind = .podcast
        }
        self.init(kind: kind, key: item.id, title: item.title, subtitle: item.subtitle, artworkURL: item.artworkURL, track: nil)
    }

    /// The page it opens (artists, albums, playlists, podcasts).
    var item: MusicItem? {
        let kind: MusicItem.Kind
        switch self.kind {
        case .artist: kind = .artist
        case .album: kind = .album
        case .playlist: kind = .playlist
        case .podcast: kind = .podcast
        case .query, .song: return nil
        }
        return MusicItem(kind: kind, id: key, title: title, subtitle: subtitle, artworkURL: artworkURL)
    }

    /// The saved history; nothing when it can't be read.
    static func decode(_ data: Data) -> [RecentSearch] {
        guard !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([RecentSearch].self, from: data)) ?? []
    }
}

/// A row of the search's history: the cover (round for an artist) or, for a search sent, a
/// magnifying glass, beside the title. Optional trailing content (classic: the green tick and ×).
private struct RecentSearchRow: View {
    let entry: RecentSearch
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 12) {
            cover
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !entry.subtitle.isEmpty {
                    Group {
                        if entry.kind == .song {
                            Text("Brano · \(entry.subtitle)")
                        } else {
                            Text(entry.subtitle)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .contentShape(.rect)
    }

    @ViewBuilder private var cover: some View {
        if let track = entry.track {
            ArtworkView(track: track, size: 48, cornerRadius: 6)
        } else if entry.kind == .query {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 6))
        } else {
            CachedImage(url: entry.artworkURL, pixels: 144) { Rectangle().fill(.quaternary) }
                .clipShape(entry.kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))
        }
    }
}

/// What the search shows, in order. YouTube Music's top result joins its own kind's row.
private struct SearchLayout {
    let namedArtist: MusicItem?
    let songs: [Track]
    let playlists: [MusicItem]
    let artists: [MusicItem]
    let albums: [MusicItem]
    let podcasts: [MusicItem]

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
        podcasts = withTop(catalog.podcasts) { $0.kind == .podcast }
    }
}

/// A tile of the classic style's "browse all": a genre or a mood, the YouTube Music search it starts.
private struct BrowseTile: Identifiable {
    let title: LocalizedStringKey
    let query: String
    let symbol: String
    let tint: Color
    var id: String { query }

    /// The two leading category cards above "Sfoglia tutto".
    static var categories: [BrowseTile] { [
        BrowseTile(title: "Musica", query: "top songs", symbol: "music.note", tint: Color(red: 0.86, green: 0.15, blue: 0.47)),
        BrowseTile(title: "Podcast", query: "podcasts", symbol: "mic.fill", tint: Color(red: 0.05, green: 0.40, blue: 0.28)),
    ] }

    static var all: [BrowseTile] { [
        BrowseTile(title: "Pop", query: "pop hits", symbol: "star.fill", tint: Color(red: 0.86, green: 0.15, blue: 0.47)),
        BrowseTile(title: "Hip-Hop", query: "hip hop hits", symbol: "music.mic", tint: Color(red: 0.73, green: 0.36, blue: 0.10)),
        BrowseTile(title: "Rock", query: "rock classics", symbol: "guitars.fill", tint: Color(red: 0.91, green: 0.07, blue: 0.16)),
        BrowseTile(title: "Dance", query: "dance hits", symbol: "figure.dance", tint: Color(red: 0.55, green: 0.10, blue: 0.80)),
        BrowseTile(title: "Elettronica", query: "electronic music", symbol: "waveform", tint: Color(red: 0.05, green: 0.45, blue: 0.93)),
        BrowseTile(title: "R&B", query: "r&b hits", symbol: "heart.fill", tint: Color(red: 0.73, green: 0.36, blue: 0.62)),
        BrowseTile(title: "Latino", query: "latin hits", symbol: "sun.max.fill", tint: Color(red: 0.88, green: 0.52, blue: 0.10)),
        BrowseTile(title: "Italiana", query: "hit italiane", symbol: "music.note", tint: Color(red: 0.12, green: 0.55, blue: 0.30)),
        BrowseTile(title: "Jazz", query: "jazz classics", symbol: "music.quarternote.3", tint: Color(red: 0.47, green: 0.36, blue: 0.24)),
        BrowseTile(title: "Classica", query: "classical music", symbol: "pianokeys", tint: Color(red: 0.30, green: 0.40, blue: 0.53)),
        BrowseTile(title: "Acustica", query: "acoustic songs", symbol: "guitars", tint: Color(red: 0.55, green: 0.45, blue: 0.20)),
        BrowseTile(title: "Pianoforte", query: "piano music", symbol: "pianokeys.inverse", tint: Color(red: 0.28, green: 0.28, blue: 0.36)),
        BrowseTile(title: "Anni '80", query: "80s hits", symbol: "radio.fill", tint: Color(red: 0.45, green: 0.20, blue: 0.75)),
        BrowseTile(title: "Relax", query: "chill relax songs", symbol: "leaf.fill", tint: Color(red: 0.15, green: 0.55, blue: 0.50)),
        BrowseTile(title: "Concentrazione", query: "lofi focus study", symbol: "brain.head.profile", tint: Color(red: 0.31, green: 0.27, blue: 0.70)),
        BrowseTile(title: "Allenamento", query: "workout gym motivation songs", symbol: "figure.run", tint: Color(red: 0.80, green: 0.33, blue: 0.05)),
        BrowseTile(title: "Festa", query: "party dance hits", symbol: "party.popper.fill", tint: Color(red: 0.83, green: 0.10, blue: 0.40)),
        BrowseTile(title: "Malinconia", query: "sad songs", symbol: "cloud.rain.fill", tint: Color(red: 0.16, green: 0.30, blue: 0.55)),
        BrowseTile(title: "Energia", query: "upbeat energetic songs", symbol: "bolt.fill", tint: Color(red: 0.75, green: 0.60, blue: 0.0)),
        BrowseTile(title: "Lounge", query: "lounge music", symbol: "wineglass.fill", tint: Color(red: 0.40, green: 0.25, blue: 0.35)),
    ] }
}

/// The tile: its colour, the name in bold at the top, a large symbol tilted in the bottom corner.
private struct BrowseTileView: View {
    let tile: BrowseTile

    var body: some View {
        ZStack(alignment: .topLeading) {
            tile.tint
            Image(systemName: tile.symbol)
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .rotationEffect(.degrees(25))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 10, y: 6)
            Text(tile.title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(12)
        }
        .frame(height: 96)
        .clipShape(.rect(cornerRadius: 6))
        .contentShape(.rect(cornerRadius: 6))
    }
}
