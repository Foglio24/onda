import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var lastfm: LastFM
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    @State private var quickPicks: [Track] = []
    /// The song the quick picks were built from; nil when they came from the generic fallback.
    @State private var quickPicksSeed: String?
    @State private var topTracks: [Track] = []
    @State private var busyItem: String?
    @State private var errorText: String?

    private struct Mood: Identifiable {
        let title: String
        let query: String
        let symbol: String
        let tint: Color
        var id: String { query }
    }

    private let moods = [
        Mood(title: String(localized: "Relax"), query: "chill relax songs", symbol: "leaf.fill", tint: .mint),
        Mood(title: String(localized: "Concentrazione"), query: "lofi focus study", symbol: "brain.head.profile",
             tint: .indigo),
        Mood(title: String(localized: "Allenamento"), query: "workout gym motivation songs", symbol: "figure.run",
             tint: .orange),
        Mood(title: String(localized: "Festa"), query: "party dance hits", symbol: "party.popper.fill", tint: .pink),
        Mood(title: String(localized: "Malinconia"), query: "sad songs", symbol: "cloud.rain.fill", tint: .blue),
        Mood(title: String(localized: "Energia"), query: "upbeat energetic songs", symbol: "bolt.fill", tint: .yellow),
        Mood(title: String(localized: "Italiana"), query: "hit italiane", symbol: "music.mic", tint: .green),
        Mood(title: String(localized: "Anni '80"), query: "80s hits", symbol: "radio.fill", tint: .purple),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if player.current == nil || player.isRestoredSession, let point = player.resumePoint {
                        section("Riprendi da dove eri") {
                            ResumeCard(point: point, accent: accent.color) { player.continueListening(point) }
                                .padding(.horizontal)
                        }
                    }
                    let shortcuts = self.shortcuts
                    if !shortcuts.isEmpty { shortcutsSection(shortcuts) }
                    let mixes = DailyMix.make(history: library.history, liked: library.liked, day: Self.today)
                    if !mixes.isEmpty { dailyMixesSection(mixes) }
                    moodsSection
                    if !quickPicks.isEmpty { quickPicksShelf }
                    if !library.history.isEmpty { recentShelf }
                }
                .padding(.vertical, 8)
            }
            .background { AmbientBackground() }
            .navigationTitle(greeting)
            .task(id: library.history.first?.videoId) {
                // Replace the generic picks with personal ones as soon as there is something to go on.
                let canPersonalize = quickPicksSeed == nil && library.history.first?.videoId != nil
                if quickPicks.isEmpty || canPersonalize { await loadQuickPicks() }
            }
            .task(id: lastfm.username) { await loadTopTracks() }
            .refreshable {
                await loadQuickPicks()
                await loadTopTracks()
            }
            .alert("Ops", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
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
            tileGrid(shortcuts, columns: 2) { shortcutTile($0) }
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

    @ViewBuilder private func shortcutTile(_ shortcut: HomeShortcut) -> some View {
        switch shortcut {
        case .liked:
            NavigationLink { TrackCollectionView(collection: .liked) } label: {
                ShortcutTile(title: String(localized: "Preferiti")) {
                    SymbolArtwork(symbol: "heart.fill", tint: .pink)
                }
            }
            .buttonStyle(.plain)
        case .downloads:
            NavigationLink { DownloadsView() } label: {
                ShortcutTile(title: String(localized: "Download")) {
                    SymbolArtwork(symbol: "arrow.down.circle.fill", tint: .blue)
                }
            }
            .buttonStyle(.plain)
        case .playlist(let playlist):
            NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                ShortcutTile(title: playlist.name) {
                    PlaylistArtwork(playlist: playlist, cornerRadius: 0)
                }
            }
            .buttonStyle(.plain)
        case .tasteMix:
            Button {
                perform(shortcut.id) {
                    let tracks = try await lastfm.tasteMix()
                    player.play(tracks, source: "Taste Mix")
                }
            } label: {
                ShortcutTile(title: "Taste Mix", busy: busyItem == shortcut.id) {
                    SymbolArtwork(symbol: "sparkles", tint: .purple)
                }
            }
            .buttonStyle(.plain)
        case .rediscover:
            Button {
                perform(shortcut.id) {
                    let tracks = try await lastfm.rediscoverMix()
                    player.play(tracks, source: String(localized: "Riscopri"))
                }
            } label: {
                ShortcutTile(title: String(localized: "Riscopri"), busy: busyItem == shortcut.id) {
                    SymbolArtwork(symbol: "arrow.counterclockwise", tint: .orange)
                }
            }
            .buttonStyle(.plain)
        case .topMonth:
            Button {
                player.play(topTracks, source: "Top Last.fm")
            } label: {
                ShortcutTile(title: String(localized: "Top del mese")) {
                    SymbolArtwork(symbol: "chart.bar.fill", tint: .red)
                }
            }
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
            tileGrid(orderedMoods, columns: 3) { mood in
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
                        TrackRow(track: track) {
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

    /// Changes once a day, so the daily mixes start from a different song.
    private static var today: Int {
        Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
    }

    // MARK: Actions

    private func playMood(_ mood: Mood) {
        perform(mood.id) {
            let found = try await InnerTube.shared.searchSongs(mood.query)
            let tracks = withoutLongMixes(found)
            guard !tracks.isEmpty else { throw InnerTubeError.notFound }
            player.play(tracks.shuffled(), source: mood.title)
        }
    }

    private func playMix(_ mix: DailyMix) {
        guard let seedID = mix.seed.videoId else { return }
        perform(mix.id) {
            let radio = try await InnerTube.shared.radio(for: seedID)
            var tracks = withoutLongMixes(radio)
            if !tracks.contains(where: { $0.videoId == seedID }) { tracks.insert(mix.seed, at: 0) }
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

    private func loadQuickPicks() async {
        do {
            if let seed = library.history.first?.videoId {
                let radio = try await InnerTube.shared.radio(for: seed)
                quickPicks = Array(withoutLongMixes(Array(radio.dropFirst())).prefix(20))
                quickPicksSeed = seed
            } else {
                let hits = try await InnerTube.shared.searchSongs("top hits")
                quickPicks = Array(withoutLongMixes(hits).prefix(20))
                quickPicksSeed = nil
            }
        } catch {
            // Keep whatever was shown before; the shelf simply stays hidden when empty.
        }
    }

    /// Drops hour-long compilations uploaded as "songs", unless the user turned the filter off.
    private func withoutLongMixes(_ tracks: [Track]) -> [Track] {
        guard Preferences.skipsLongMixes else { return tracks }
        return tracks.filter { ($0.duration ?? 0) <= Preferences.longMixThreshold }
    }

    private func loadTopTracks() async {
        guard lastfm.isConnected else {
            topTracks = []
            return
        }
        topTracks = (try? await lastfm.topTracks(period: "1month", limit: 20)) ?? []
    }
}
