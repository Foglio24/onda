import AVKit
import SafariServices
import SwiftUI

/// Square cover art: the downloaded file when there is one, otherwise the YouTube Music thumbnail.
struct ArtworkView: View {
    let track: Track?
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = 8
    var highRes = false

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay { image }
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: cornerRadius))
    }

    private var url: URL? {
        guard let track else { return nil }
        if let local = Storage.localArtwork(for: track) { return local }
        return highRes ? track.largeArtworkURL : track.mediumArtworkURL
    }

    @ViewBuilder private var image: some View {
        if let url {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: "music.note")
            .font(.system(size: (size ?? 160) * 0.35))
            .foregroundStyle(.secondary)
    }
}

/// Cover for a playlist: the photo the user picked, else a 2×2 mosaic of its first songs,
/// a single cover, or a gradient.
struct PlaylistArtwork: View {
    let playlist: Playlist
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = 12

    var body: some View {
        let covers = Array(playlist.tracks.prefix(4))
        Rectangle()
            .fill(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if let custom = playlist.customCoverURL {
                    AsyncImage(url: custom) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                } else if covers.count == 4 {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            ArtworkView(track: covers[0], cornerRadius: 0)
                            ArtworkView(track: covers[1], cornerRadius: 0)
                        }
                        GridRow {
                            ArtworkView(track: covers[2], cornerRadius: 0)
                            ArtworkView(track: covers[3], cornerRadius: 0)
                        }
                    }
                } else if let first = covers.first {
                    ArtworkView(track: first, cornerRadius: 0)
                } else {
                    Image(systemName: "music.note.list")
                        .font(.system(size: (size ?? 160) * 0.32, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: cornerRadius))
    }
}

/// Soft background tinted with the colours of the song that is playing.
struct AmbientBackground: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemBackground)
            LinearGradient(colors: [player.artworkColor.opacity(0.6), player.artworkColor.opacity(0.18), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 560)
            RadialGradient(colors: [player.artworkColor.opacity(0.35), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: player.artworkColor)
    }
}

/// A song in a list: tap to play, "···" for every action, swipe right to like or add to a playlist.
struct TrackRow: View {
    let track: Track
    var showsMenu = true
    let action: () -> Void

    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var router: AppRouter

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 12) {
                    artwork
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if library.isLiked(track) {
                                Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink)
                            }
                            if downloads.isDownloaded(track) {
                                Image(systemName: "arrow.down.circle.fill").font(.caption2)
                            }
                            Text(track.subtitle).lineLimit(1)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    trailing
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showsMenu {
                Menu {
                    TrackMenu(track: track)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 44)
                        .contentShape(.rect)
                }
            }
        }
        .contextMenu { TrackMenu(track: track) }
        .onAppear { StreamPrewarmer.shared.request(track) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { library.toggleLike(track) } label: {
                Label(library.isLiked(track) ? "Non mi piace" : "Mi piace",
                      systemImage: library.isLiked(track) ? "heart.slash.fill" : "heart.fill")
            }
            .tint(.pink)
            Button { router.trackToAdd = track } label: {
                Label("Playlist", systemImage: "text.badge.plus")
            }
            .tint(.indigo)
        }
    }

    private var artwork: some View {
        ArtworkView(track: track, size: 50, cornerRadius: 6)
            .overlay {
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.45), in: .rect(cornerRadius: 6))
                }
            }
    }

    @ViewBuilder private var trailing: some View {
        if let videoId = track.videoId, let value = downloads.progress[videoId] {
            Text(value, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else if let duration = track.duration {
            Text(duration.formattedTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Large artwork card used in horizontal shelves.
struct TrackCard: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: track, size: 150, cornerRadius: 14)
            Text(track.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(track.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(.rect)
        .contextMenu { TrackMenu(track: track) }
        .onAppear { StreamPrewarmer.shared.request(track) }
    }
}

struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlaylistArtwork(playlist: playlist, size: 150, cornerRadius: 14)
            Text(playlist.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(playlist.countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(.rect)
    }
}

/// "Riproduci" and "Casuale" buttons shown above a list of songs.
struct PlayShuffleButtons: View {
    let tracks: [Track]
    let source: String
    @EnvironmentObject private var player: PlayerController
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.play(tracks, source: source, shuffled: false)
            } label: {
                Label("Riproduci", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(accent.color.opacity(0.55)).interactive(), in: .capsule)

            Button {
                player.play(tracks, startAt: Int.random(in: tracks.indices), source: source, shuffled: true)
            } label: {
                Label("Casuale", systemImage: "shuffle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .disabled(tracks.isEmpty)
    }
}

/// The actions available on every song, used in "···" menus, context menus and the player.
struct TrackMenu: View {
    let track: Track
    var inPlayer = false
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        if !inPlayer {
            Button { player.playNext(track) } label: {
                Label("Riproduci dopo", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { player.addToQueue(track) } label: {
                Label("Aggiungi in coda", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
        Button { player.playRadio(from: track) } label: {
            Label("Avvia radio", systemImage: "dot.radiowaves.left.and.right")
        }
        Divider()
        Button { library.toggleLike(track) } label: {
            if library.isLiked(track) {
                Label("Togli dai preferiti", systemImage: "heart.slash")
            } else {
                Label("Aggiungi ai preferiti", systemImage: "heart")
            }
        }
        Button { router.trackToAdd = track } label: {
            Label("Aggiungi a playlist…", systemImage: "text.badge.plus")
        }
        if let videoId = track.videoId {
            if downloads.isDownloaded(track) {
                Button(role: .destructive) { downloads.remove(track) } label: {
                    Label("Rimuovi download", systemImage: "trash")
                }
            } else if downloads.progress[videoId] == nil {
                Button { downloads.download(track) } label: {
                    Label("Scarica", systemImage: "arrow.down.circle")
                }
            }
        }
        if let url = track.shareURL {
            ShareLink(item: url) {
                Label("Condividi", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// Lives in the tab bar's bottom accessory, like the Music app.
struct MiniPlayer: View {
    @EnvironmentObject private var player: PlayerController
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(track: player.current, size: 32, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Niente in riproduzione")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if player.current != nil {
                Button { player.togglePlayPause() } label: {
                    Group {
                        if player.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .font(.title3)
                    .frame(width: 34, height: 34)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                }
            }
        }
        .padding(.horizontal, 12)
        .buttonStyle(.plain)
        .contentShape(.rect)
        .onTapGesture {
            if player.current != nil { onOpen() }
        }
    }

    private var subtitle: String? {
        if let error = player.errorMessage { return error }
        return player.current?.artist
    }
}

struct AirPlayButton: UIViewRepresentable {
    var activeTint: Color

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.activeTintColor = UIColor(activeTint)
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
