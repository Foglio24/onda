import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var lastfm: LastFM

    @State private var quickPicks: [Track] = []
    @State private var topTracks: [Track] = []
    @State private var busyItem: String?
    @State private var errorText: String?

    private struct Mood: Identifiable {
        let title: String
        let query: String
        let symbol: String
        var id: String { title }
    }

    private let moods = [
        Mood(title: "Relax", query: "chill relax songs", symbol: "leaf.fill"),
        Mood(title: "Concentrazione", query: "lofi focus study", symbol: "brain.head.profile"),
        Mood(title: "Allenamento", query: "workout gym motivation songs", symbol: "figure.run"),
        Mood(title: "Festa", query: "party dance hits", symbol: "party.popper.fill"),
        Mood(title: "Malinconia", query: "sad songs", symbol: "cloud.rain.fill"),
        Mood(title: "Energia", query: "upbeat energetic songs", symbol: "bolt.fill"),
        Mood(title: "Italiana", query: "hit italiane", symbol: "music.mic"),
        Mood(title: "Anni '80", query: "80s hits", symbol: "radio.fill"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    moodChips
                    if lastfm.isConnected { mixCards }
                    if !quickPicks.isEmpty { quickPicksShelf }
                    if !library.history.isEmpty { recentShelf }
                    if !topTracks.isEmpty { topTracksList }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle(greeting)
            .task { if quickPicks.isEmpty { await loadQuickPicks() } }
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

    private var moodChips: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(moods) { mood in
                        Button { playMood(mood) } label: {
                            HStack(spacing: 6) {
                                if busyItem == mood.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: mood.symbol)
                                }
                                Text(mood.title).fontWeight(.semibold)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var mixCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("I tuoi mix")
            HStack(spacing: 12) {
                mixCard(id: "taste", title: "Taste Mix", subtitle: "Brani simili a quelli che ami",
                        symbol: "sparkles", tint: .purple) { try await lastfm.tasteMix() }
                mixCard(id: "rediscover", title: "Riscopri", subtitle: "I tuoi più ascoltati dell'anno",
                        symbol: "arrow.counterclockwise", tint: .orange) { try await lastfm.rediscoverMix() }
            }
            .padding(.horizontal)
        }
    }

    private func mixCard(id: String, title: String, subtitle: String, symbol: String, tint: Color,
                         build: @escaping () async throws -> [Track]) -> some View {
        Button {
            perform(id) {
                let tracks = try await build()
                player.play(tracks, source: title)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol).font(.title2)
                    Spacer()
                    if busyItem == id { ProgressView() }
                }
                Spacer(minLength: 16)
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            .glassEffect(.regular.tint(tint.opacity(0.35)).interactive(), in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    private var quickPicksShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Scelti per te")
            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(58), spacing: 8), count: 4), spacing: 20) {
                    ForEach(Array(quickPicks.enumerated()), id: \.element.id) { position, track in
                        Button {
                            player.play(quickPicks, startAt: position, source: "Scelti per te")
                        } label: {
                            TrackRow(track: track).frame(width: 300)
                        }
                        .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Ascoltati di recente")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(library.history.prefix(20))) { track in
                        Button { player.playRadio(from: track) } label: { TrackCard(track: track) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var topTracksList: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("I tuoi top del mese su Last.fm")
            VStack(spacing: 10) {
                ForEach(Array(topTracks.prefix(10).enumerated()), id: \.element.id) { position, track in
                    Button {
                        player.play(topTracks, startAt: position, source: "Top Last.fm")
                    } label: {
                        HStack(spacing: 14) {
                            Text("\(position + 1)")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            TrackRow(track: track)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title2.bold())
            .padding(.horizontal)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: return "Buongiorno"
        case 12..<18: return "Buon pomeriggio"
        default: return "Buonasera"
        }
    }

    // MARK: Actions

    private func playMood(_ mood: Mood) {
        perform(mood.id) {
            let tracks = try await InnerTube.shared.searchSongs(mood.query)
            guard !tracks.isEmpty else { throw InnerTubeError.notFound }
            player.play(tracks.shuffled(), source: mood.title)
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
                quickPicks = Array(radio.dropFirst().prefix(20))
            } else {
                let hits = try await InnerTube.shared.searchSongs("top hits")
                quickPicks = Array(hits.prefix(20))
            }
        } catch {
            // Keep whatever was shown before; the shelf simply stays hidden when empty.
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
