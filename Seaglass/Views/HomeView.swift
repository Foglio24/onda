import SwiftUI

struct HomeView: View {
    /// Regular on an iPad: more tiles to a row.
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Which song plays, not the whole player: the Home doesn't redraw for every player change.
    @EnvironmentObject private var nowPlaying: NowPlayingState
    private var player: PlayerController { .shared }
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var lastfm: LastFM
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    @State private var quickPicks: [Track] = []
    @State private var topTracks: [Track] = []
    @State private var busyItem: String?
    @State private var errorText: String?

    private struct Mood: Identifiable {
        let title: String
        /// YouTube Music searches for the mood, one a day (see `Recommendations.moodTracks`).
        let queries: [String]
        let symbol: String
        let tint: Color
        var query: String { queries[0] }
        var id: String { query }
    }

    private let moods = [
        Mood(title: String(localized: "Relax"),
             queries: ["chill relax songs", "acoustic chill", "chill pop", "soft rock chill", "lofi chill beats"],
             symbol: "leaf.fill", tint: .mint),
        Mood(title: String(localized: "Concentrazione"),
             queries: ["lofi focus study", "deep focus instrumental", "piano focus", "ambient study music", "chillhop study"],
             symbol: "brain.head.profile", tint: .indigo),
        Mood(title: String(localized: "Allenamento"),
             queries: ["workout gym motivation songs", "running songs", "hip hop workout", "edm workout", "rock workout"],
             symbol: "figure.run", tint: .orange),
        Mood(title: String(localized: "Festa"),
             queries: ["party dance hits", "dance pop party", "reggaeton party", "house party hits", "2000s party songs"],
             symbol: "party.popper.fill", tint: .pink),
        Mood(title: String(localized: "Malinconia"),
             queries: ["sad songs", "sad pop ballads", "heartbreak songs", "sad indie", "acoustic sad songs"],
             symbol: "cloud.rain.fill", tint: .blue),
        Mood(title: String(localized: "Energia"),
             queries: ["upbeat energetic songs", "feel good songs", "happy upbeat pop", "good vibes songs", "summer hits"],
             symbol: "bolt.fill", tint: .yellow),
        Mood(title: String(localized: "Italiana"),
             queries: ["hit italiane", "pop italiano", "rap italiano", "cantautori italiani", "indie italiano"],
             symbol: "music.mic", tint: .green),
        Mood(title: String(localized: "Anni '80"),
             queries: ["80s hits", "80s synthpop", "80s rock anthems", "italo disco", "80s dance hits"],
             symbol: "radio.fill", tint: .purple),
    ]

    /// On a Mac the Home is laid out as Apple Music's: big cards for the mixes, square covers, the
    /// moods as coloured cards, rows that scroll by page.
    private static let isMac = ProcessInfo.processInfo.isMacCatalystApp

    var body: some View {
        NavigationStack {
            ScrollView {
                if Self.isMac {
                    macSections
                } else {
                    phoneSections
                }
            }
            // In the colours of the song playing, as the other pages (on a Mac too).
            .background { AmbientBackground() }
            .navigationTitle(Self.isMac ? String(localized: "Home") : greeting)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { RecognitionButton() }
            }
            // Once a day, and as soon as there is a first song to go on.
            .task(id: "\(Recommendations.today)|\(library.history.isEmpty)") {
                quickPicks = await Recommendations.quickPicks(refresh: false)
            }
            .task(id: lastfm.username) { await loadTopTracks() }
            .refreshable {
                // New "Scelti per te"; the daily mixes stay the day's.
                quickPicks = await Recommendations.quickPicks(refresh: true)
                await loadTopTracks()
            }
            .alert("Ops", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private var phoneSections: some View {
        VStack(alignment: .leading, spacing: 30) {
            if nowPlaying.isIdle, let point = player.resumePoint {
                section("Riprendi da dove eri") {
                    ResumeCard(point: point, accent: accent.color) { player.continueListening(point) }
                        .padding(.horizontal)
                }
            }
            let shortcuts = self.shortcuts
            if !shortcuts.isEmpty { shortcutsSection(shortcuts) }
            let mixes = Recommendations.dailyMixes()
            if !mixes.isEmpty { dailyMixesSection(mixes) }
            moodsSection
            if !quickPicks.isEmpty { quickPicksShelf }
            if !library.history.isEmpty { recentShelf }
        }
        .padding(.vertical, 8)
    }

    // MARK: Sections

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .padding(.horizontal)
            content()
        }
    }

    /// Favourites, mixes, the playlists in use and downloads, up to six.
    private var shortcuts: [HomeShortcut] {
        let playlists = PlaylistUsage.sorted(library.playlists).map(HomeShortcut.playlist)
        var items: [HomeShortcut] = []
        if !library.liked.isEmpty { items.append(.liked) }
        if lastfm.isConnected { items.append(.tasteMix) }
        items += playlists.prefix(2)
        if lastfm.isConnected { items.append(.rediscover) }
        if !topTracks.isEmpty { items.append(.topMonth) }
        if !library.downloads.isEmpty { items.append(.downloads) }
        items += playlists.dropFirst(2)
        return Array(items.prefix(6))
    }

    private func shortcutsSection(_ shortcuts: [HomeShortcut]) -> some View {
        section("Accesso rapido") {
            tileGrid(shortcuts, columns: sizeClass == .regular ? 3 : 2) { shortcutTile($0) }
                .padding(.horizontal)
        }
    }

    /// A plain grid of glass tiles. A LazyVGrid inside a GlassEffectContainer left some tiles
    /// undrawn on iOS 26, so these few tiles go in ordinary rows, each glass on its own.
    private func tileGrid<Item: Identifiable, Tile: View>(_ items: [Item], columns: Int,
                                                          @ViewBuilder tile: @escaping (Item) -> Tile) -> some View {
        let rows = stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0..<min($0 + columns, items.count)])
        }
        return VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(rows[row]) { item in tile(item) }
                    // Keeps the last row's tiles as wide as the others.
                    ForEach(rows[row].count..<columns, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
    }

    private func shortcutTile(_ shortcut: HomeShortcut) -> some View {
        shortcutLink(shortcut) {
            ShortcutTile(title: title(of: shortcut), busy: busyItem == shortcut.id) { artwork(of: shortcut) }
        }
    }

    private func title(of shortcut: HomeShortcut) -> String {
        switch shortcut {
        case .liked: return String(localized: "Preferiti")
        case .downloads: return String(localized: "Download")
        case .playlist(let playlist): return playlist.name
        case .tasteMix: return "Taste Mix"
        case .rediscover: return String(localized: "Riscopri")
        case .topMonth: return String(localized: "Top del mese")
        }
    }

    @ViewBuilder private func artwork(of shortcut: HomeShortcut) -> some View {
        switch shortcut {
        case .liked: SymbolArtwork(symbol: "heart.fill", tint: .pink)
        case .downloads: SymbolArtwork(symbol: "arrow.down.circle.fill", tint: .blue)
        case .playlist(let playlist): PlaylistArtwork(playlist: playlist, cornerRadius: 0)
        case .tasteMix: SymbolArtwork(symbol: "sparkles", tint: .purple)
        case .rediscover: SymbolArtwork(symbol: "arrow.counterclockwise", tint: .orange)
        case .topMonth: SymbolArtwork(symbol: "chart.bar.fill", tint: .red)
        }
    }

    /// What a shortcut opens (favourites, downloads, a playlist) or plays (the Last.fm mixes).
    @ViewBuilder private func shortcutLink<Label: View>(_ shortcut: HomeShortcut,
                                                        @ViewBuilder label: () -> Label) -> some View {
        switch shortcut {
        case .liked:
            NavigationLink { TrackCollectionView(collection: .liked) } label: { label() }
                .buttonStyle(.plain)
        case .downloads:
            NavigationLink { DownloadsView() } label: { label() }
                .buttonStyle(.plain)
        case .playlist(let playlist):
            NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: { label() }
                .buttonStyle(.plain)
        case .tasteMix:
            Button {
                perform(shortcut.id) {
                    let tracks = try await lastfm.tasteMix()
                    player.play(tracks, source: "Taste Mix")
                }
            } label: { label() }
            .buttonStyle(.plain)
        case .rediscover:
            Button {
                perform(shortcut.id) {
                    let tracks = try await lastfm.rediscoverMix()
                    player.play(tracks, source: String(localized: "Riscopri"))
                }
            } label: { label() }
            .buttonStyle(.plain)
        case .topMonth:
            Button {
                player.play(topTracks, source: "Top Last.fm")
            } label: { label() }
            .buttonStyle(.plain)
        }
    }

    private func dailyMixesSection(_ mixes: [DailyMix]) -> some View {
        section("I tuoi mix del giorno") {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(mixes) { mix in
                        Button { playMix(mix) } label: {
                            DailyMixCard(mix: mix, busy: busyItem == mix.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var moodsSection: some View {
        section("Mood") {
            tileGrid(orderedMoods, columns: sizeClass == .regular ? 4 : 3) { mood in
                Button { playMood(mood) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        if busyItem == mood.id {
                            ProgressView().controlSize(.small)
                                .frame(height: 22)
                        } else {
                            Image(systemName: mood.symbol)
                                .font(.title3)
                                .frame(height: 22)
                        }
                        Text(mood.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect(cornerRadius: 18))
                    .glassEffect(.regular.tint(mood.tint.opacity(0.3)).interactive(),
                                 in: .rect(cornerRadius: 18))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
    }

    /// The moods that suit the time of day come first: energy in the morning, calm in the evening.
    private var orderedMoods: [Mood] {
        let first: [String]
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: first = ["upbeat energetic songs", "workout gym motivation songs", "lofi focus study"]
        case 12..<18: first = ["lofi focus study", "party dance hits"]
        default: first = ["chill relax songs", "sad songs"]
        }
        let preferred = first.compactMap { query in moods.first { $0.query == query } }
        return preferred + moods.filter { !first.contains($0.query) }
    }

    private var quickPicksShelf: some View {
        section("Scelti per te") {
            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(58), spacing: 8), count: 4), spacing: 20) {
                    ForEach(Array(quickPicks.enumerated()), id: \.element.id) { position, track in
                        // The shelf scrolls sideways: no swipes on its songs.
                        TrackRow(track: track, swipe: .none) {
                            player.play(quickPicks, startAt: position, source: String(localized: "Scelti per te"))
                        }
                        .frame(width: 320)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }

    private var recentShelf: some View {
        section("Ascoltati di recente") {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(library.history.prefix(20)) { track in
                        Button { player.playRadio(from: track) } label: { TrackCard(track: track, size: 112) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: return String(localized: "Buongiorno")
        case 12..<18: return String(localized: "Buon pomeriggio")
        default: return String(localized: "Buonasera")
        }
    }

    // MARK: Mac

    /// Apple Music's margins on a Mac.
    private static let macMargin: CGFloat = 28

    private var macSections: some View {
        VStack(alignment: .leading, spacing: 26) {
            if nowPlaying.isIdle, let point = player.resumePoint {
                VStack(alignment: .leading, spacing: 12) {
                    macHeader("Riprendi da dove eri")
                    ResumeCard(point: point, accent: accent.color) { player.continueListening(point) }
                        .frame(maxWidth: 560)
                        .padding(.horizontal, Self.macMargin)
                }
            }
            let mixes = Recommendations.dailyMixes()
            if !mixes.isEmpty {
                MacShelf(title: "I tuoi mix del giorno", count: mixes.count, itemWidth: 230, margin: Self.macMargin) { position in
                    let mix = mixes[position]
                    Button { playMix(mix) } label: {
                        MacPickCard(caption: String(localized: "Mix \(mix.number)"),
                                    title: String(localized: "\(mix.artist) e simili"), busy: busyItem == mix.id) {
                            PlaylistArtwork(playlist: Playlist(id: UUID(), name: mix.artist, tracks: mix.covers,
                                                               createdAt: .distantPast), cornerRadius: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if !library.history.isEmpty {
                let recent = Array(library.history.prefix(20))
                MacShelf(title: "Ascoltati di recente", count: recent.count, itemWidth: 180, margin: Self.macMargin) { position in
                    let track = recent[position]
                    Button { player.playRadio(from: track) } label: {
                        MacCoverCard(title: track.title, subtitle: track.artist) {
                            ArtworkView(track: track, cornerRadius: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TrackMenu(track: track) }
                    .playbackWarmup(track)
                }
            }
            let shortcuts = self.shortcuts
            if !shortcuts.isEmpty {
                MacShelf(title: "Accesso rapido", count: shortcuts.count, itemWidth: 180, margin: Self.macMargin) { position in
                    let shortcut = shortcuts[position]
                    shortcutLink(shortcut) {
                        MacCoverCard(title: title(of: shortcut), subtitle: subtitle(of: shortcut),
                                     busy: busyItem == shortcut.id, plays: plays(shortcut)) { artwork(of: shortcut) }
                    }
                }
            }
            if !quickPicks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    macHeader("Scelti per te")
                    ScrollView(.horizontal) {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(58), spacing: 8), count: 4), spacing: 24) {
                            ForEach(Array(quickPicks.enumerated()), id: \.element.id) { position, track in
                                TrackRow(track: track, swipe: .none) {
                                    player.play(quickPicks, startAt: position, source: String(localized: "Scelti per te"))
                                }
                                .frame(width: 380)
                            }
                        }
                        .scrollTargetLayout()
                        // Room for the Mac's scroll bar under the rows.
                        .padding(.bottom, 12)
                    }
                    .contentMargins(.horizontal, Self.macMargin, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                macHeader("Mood")
                tileGrid(orderedMoods, columns: 4) { mood in
                    Button { playMood(mood) } label: {
                        MacMoodCard(title: mood.title, symbol: mood.symbol, tint: mood.tint, busy: busyItem == mood.id)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Self.macMargin)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 24)
    }

    private func macHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title2.bold())
            .padding(.horizontal, Self.macMargin)
    }

    /// Whether a shortcut plays (the Last.fm mixes) rather than opening a page.
    private func plays(_ shortcut: HomeShortcut) -> Bool {
        switch shortcut {
        case .tasteMix, .rediscover, .topMonth: return true
        case .liked, .downloads, .playlist: return false
        }
    }

    /// The line under a shortcut's cover: how many songs, where there is a count.
    private func subtitle(of shortcut: HomeShortcut) -> String? {
        switch shortcut {
        case .liked: return String(localized: "\(library.liked.count) brani")
        case .downloads: return String(localized: "\(library.downloads.count) brani")
        case .playlist(let playlist): return String(localized: "\(playlist.tracks.count) brani")
        case .topMonth: return String(localized: "\(topTracks.count) brani")
        case .tasteMix, .rediscover: return "Last.fm"
        }
    }

    // MARK: Actions

    private func playMood(_ mood: Mood) {
        perform(mood.id) {
            let tracks = try await Recommendations.moodTracks(queries: mood.queries)
            player.play(tracks, source: mood.title)
        }
    }

    private func playMix(_ mix: DailyMix) {
        perform(mix.id) {
            let tracks = try await Recommendations.tracks(for: mix)
            guard !tracks.isEmpty else { throw InnerTubeError.notFound }
            player.play(tracks, source: String(localized: "Mix del giorno · \(mix.artist)"))
        }
    }

    /// Runs one action at a time, showing a spinner on the element that started it.
    private func perform(_ id: String, _ work: @escaping () async throws -> Void) {
        guard busyItem == nil else { return }
        busyItem = id
        Task {
            do {
                try await work()
            } catch {
                errorText = error.localizedDescription
            }
            busyItem = nil
        }
    }

    private func loadTopTracks() async {
        guard lastfm.isConnected else {
            topTracks = []
            return
        }
        topTracks = (try? await lastfm.topTracks(period: "1month", limit: 20)) ?? []
    }
}
