import SwiftUI

/// An artist, album or playlist page, opened as a sheet from anywhere (see `AppRouter.page`).
struct MusicPageSheet: View {
    let page: MusicPage
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        NavigationStack {
            MusicPageView(page: page)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fine") { router.page = nil }
                    }
                }
        }
        .sheet(item: router.addToPlaylistBinding(for: .page)) { track in
            AddToPlaylistSheet(track: track)
        }
    }
}

struct MusicPageView: View {
    let page: MusicPage

    var body: some View {
        switch page {
        case .artist(let id, let name): ArtistView(id: id, name: name)
        case .album(let id): AlbumView(id: id)
        case .playlist(let id, let title): RemotePlaylistView(id: id, title: title)
        }
    }
}

/// Opens the item's page, or plays it when it is a song or video.
struct MusicLink<Label: View>: View {
    let item: MusicItem
    @ViewBuilder let label: Label
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        if case .song(let track) = item.kind {
            Button { player.playRadio(from: track) } label: { label }
                .buttonStyle(.plain)
        } else if let page = MusicPage(item) {
            NavigationLink { MusicPageView(page: page) } label: { label }
                .buttonStyle(.plain)
        }
    }
}

/// Square card (round for artists) used in horizontal shelves.
struct MusicItemCard: View {
    let item: MusicItem
    var size: CGFloat = 140

    var body: some View {
        VStack(alignment: item.isArtist ? .center : .leading, spacing: 6) {
            CachedImage(url: item.artworkURL, pixels: Int(size * 3)) {
                Rectangle().fill(.quaternary)
            }
            .frame(width: size, height: size)
            .clipShape(item.isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 14)))
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size, alignment: item.isArtist ? .center : .leading)
        .contentShape(.rect)
    }
}

/// A list row for an artist, album or playlist (search's top result). The list adds the chevron.
struct MusicItemRow: View {
    let item: MusicItem

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(url: item.artworkURL, pixels: 192) { Rectangle().fill(.quaternary) }
                .frame(width: 64, height: 64)
                .clipShape(item.isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

/// A horizontal row of cards with a title.
struct MusicShelfView: View {
    let title: String
    let items: [MusicItem]
    var size: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        MusicLink(item: item) { MusicItemCard(item: item, size: size) }
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// Loading and failure states shared by the pages.
private struct PageState<Content: View>: View {
    let isLoaded: Bool
    let failure: String?
    let failureTitle: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        if isLoaded {
            content
        } else if let failure {
            ContentUnavailableView(failureTitle, systemImage: "wifi.exclamationmark", description: Text(failure))
                .padding(.top, 80)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 140)
        }
    }
}

// MARK: Artist

struct ArtistView: View {
    let id: String?
    let name: String

    @EnvironmentObject private var player: PlayerController
    @State private var page: ArtistPage?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            PageState(isLoaded: page != nil, failure: failure, failureTitle: "Artista non disponibile") {
                if let page { content(page) }
            }
        }
        .background { AmbientBackground() }
        .navigationTitle(page?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard page == nil else { return }
        do {
            var browseId = id
            if browseId == nil { browseId = try await InnerTube.shared.artistID(named: name) }
            guard let browseId else { throw InnerTubeError.notFound }
            page = try await InnerTube.shared.artist(browseId)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func content(_ page: ArtistPage) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(spacing: 14) {
                CachedImage(url: page.artworkURL, pixels: 660) { Circle().fill(.quaternary) }
                    .frame(width: 210, height: 210)
                    .clipShape(.circle)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                Text(page.name)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                if let first = page.topSongs.first {
                    PlayShuffleButtons(tracks: page.topSongs, source: page.name)
                    Button { player.playRadio(from: first) } label: {
                        Label("Radio dell'artista", systemImage: "dot.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)

            if !page.topSongs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Brani più ascoltati")
                        .font(.title3.bold())
                    ForEach(Array(page.topSongs.enumerated()), id: \.offset) { position, track in
                        TrackRow(track: track) {
                            player.play(page.topSongs, startAt: position, source: page.name)
                        }
                    }
                    if let playlist = page.songsPlaylistID {
                        NavigationLink {
                            RemotePlaylistView(id: playlist, title: String(localized: "\(page.name): tutti i brani"))
                        } label: {
                            Label("Tutti i brani", systemImage: "music.note.list")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding(.horizontal)
            }

            ForEach(page.shelves) { shelf in
                MusicShelfView(title: shelf.title, items: shelf.items)
            }

            if let about = page.about, !about.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Informazioni")
                        .font(.title3.bold())
                    Text(about)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(10)
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }
}

// MARK: Album

struct AlbumView: View {
    let id: String

    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @State private var page: AlbumPage?
    @State private var failure: String?
    @State private var saved = false

    var body: some View {
        ScrollView {
            PageState(isLoaded: page != nil, failure: failure, failureTitle: "Album non disponibile") {
                if let page { content(page) }
            }
        }
        .background { AmbientBackground() }
        .navigationTitle(page?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard page == nil else { return }
            do {
                page = try await InnerTube.shared.album(id)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func content(_ page: AlbumPage) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 10) {
                CachedImage(url: page.artworkURL, pixels: 720) { Rectangle().fill(.quaternary) }
                    .frame(width: 230, height: 230)
                    .clipShape(.rect(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                Text(page.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                NavigationLink {
                    ArtistView(id: page.artistID, name: page.artist)
                } label: {
                    Text(page.artist)
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                Text([page.kindAndYear, page.details].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                PlayShuffleButtons(tracks: page.tracks, source: page.title)
                HStack(spacing: 10) {
                    Button {
                        downloads.downloadAll(page.tracks)
                    } label: {
                        Label("Scarica", systemImage: "arrow.down.circle")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    Button {
                        library.createPlaylist(named: page.title, tracks: page.tracks)
                        saved = true
                    } label: {
                        Label(saved ? "Salvato" : "Salva come playlist",
                              systemImage: saved ? "checkmark" : "text.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .disabled(saved)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(page.tracks.enumerated()), id: \.offset) { position, track in
                    HStack(spacing: 10) {
                        Text("\(position + 1)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        TrackRow(track: track) {
                            player.play(page.tracks, startAt: position, source: page.title)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: YouTube playlist

/// A public YouTube Music playlist (an artist's songs, featured playlists), shown without importing it.
struct RemotePlaylistView: View {
    let id: String
    let title: String

    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: Library
    @State private var tracks: [Track]?
    @State private var loadedTitle: String?
    @State private var failure: String?
    @State private var saved = false

    var body: some View {
        ScrollView {
            PageState(isLoaded: tracks != nil, failure: failure, failureTitle: "Playlist non disponibile") {
                if let tracks { content(tracks) }
            }
        }
        .background { AmbientBackground() }
        .navigationTitle(loadedTitle ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard tracks == nil else { return }
            do {
                let result = try await InnerTube.shared.playlist(id: id)
                loadedTitle = result.title
                tracks = result.tracks
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func content(_ tracks: [Track]) -> some View {
        let name = loadedTitle ?? title
        return VStack(alignment: .leading, spacing: 16) {
            Text(name)
                .font(.title2.bold())
            Text("\(tracks.count) brani")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            PlayShuffleButtons(tracks: tracks, source: name)
            Button {
                library.createPlaylist(named: name, tracks: tracks)
                saved = true
            } label: {
                Label(saved ? "Salvato" : "Salva come playlist", systemImage: saved ? "checkmark" : "text.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .disabled(saved)
            ForEach(Array(tracks.enumerated()), id: \.offset) { position, track in
                TrackRow(track: track) {
                    player.play(tracks, startAt: position, source: name)
                }
            }
        }
        .padding()
    }
}
