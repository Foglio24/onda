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

    private var image: some View {
        CachedImage(url: url, pixels: pixels) { placeholder }
    }

    /// Three pixels per point, the iPhone's screen scale; sizeless covers fill most of the width.
    private var pixels: Int {
        if let size { return Int(size * 3) }
        return highRes ? 1080 : 600
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
                    CachedImage(url: custom, pixels: Int((size ?? 300) * 3)) { Color.clear }
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

/// A song in a list: tap to play, "···" for every action. Swiped as on Spotify: to the right it goes
/// into the queue, to the left into the favourites, with a note at the bottom of the screen (tapped,
/// it offers the playlists instead).
struct TrackRow: View {
    /// How the row is swiped: with the list's own swipe actions, by dragging the row itself (outside
    /// lists, where those don't exist), or not at all (in shelves that scroll sideways).
    enum Swipe {
        case list, drag, none
    }

    let track: Track
    var showsMenu = true
    var swipe: Swipe = .list
    /// Swiping right adds the song to the queue (not in the queue itself).
    var queues = true
    /// Takes the song out of its list: the "Rimuovi" next to the favourites in the list's swipe.
    var remove: (() -> Void)?
    let action: () -> Void

    @EnvironmentObject private var nowPlaying: NowPlayingState
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @State private var dragOffset: CGFloat = 0
    // Only for actions. Observing them would redraw every row on screen for each player change
    // (loading, karaoke progress, lyrics…); `NowPlayingState` says just which song plays.
    private var router: AppRouter { .shared }

    private var isCurrent: Bool { nowPlaying.currentID == track.id }

    /// How far a dragged row goes before letting go does something.
    private static let dragThreshold: CGFloat = 72

    var body: some View {
        switch swipe {
        case .list:
            row
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if queues {
                        Button(action: addToQueue) {
                            Label("In coda", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                        .tint(.green)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(action: like) {
                        Label("Mi piace", systemImage: "heart.fill")
                    }
                    .tint(.pink)
                    if let remove {
                        Button(role: .destructive, action: remove) {
                            Label("Rimuovi", systemImage: "trash")
                        }
                    }
                }
        case .drag:
            row
                .offset(x: dragOffset)
                .background { dragHint }
                .gesture(HorizontalPan { translation in
                    // The row follows the finger, held back further out.
                    let limited = queues ? translation : min(0, translation)
                    dragOffset = 110 * tanh(limited / 160)
                } ended: { _ in
                    if dragOffset >= Self.dragThreshold * 0.95 { addToQueue() }
                    if dragOffset <= -Self.dragThreshold * 0.95 { like() }
                    withAnimation(.spring(duration: 0.3, bounce: 0.25)) { dragOffset = 0 }
                })
                .sensoryFeedback(.impact(weight: .medium), trigger: abs(dragOffset) >= Self.dragThreshold * 0.95) { _, reached in
                    reached
                }
        case .none:
            row
        }
    }

    /// What letting go of a dragged row will do: the queue on the left, the heart on the right.
    private var dragHint: some View {
        let progress = min(1, abs(dragOffset) / (Self.dragThreshold * 0.95))
        return HStack {
            if dragOffset > 0 {
                Image(systemName: "text.line.last.and.arrowtriangle.forward")
                    .foregroundStyle(.green)
                Spacer()
            } else if dragOffset < 0 {
                Spacer()
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
            }
        }
        .font(.title3.weight(.semibold))
        .scaleEffect(0.6 + 0.4 * progress)
        .opacity(Double(progress))
        .padding(.horizontal, 10)
    }

    private func addToQueue() {
        let player = PlayerController.shared
        // With nothing playing, the song simply starts.
        let playing = player.current != nil
        player.addToQueue(track)
        guard playing else { return }
        router.show(TrackToast(text: String(localized: "Aggiunto alla coda"),
                               systemImage: "text.line.last.and.arrowtriangle.forward", track: track))
    }

    /// Into the favourites (a song already there stays); the note offers the playlists.
    private func like() {
        let already = library.isLiked(track)
        if !already { library.toggleLike(track) }
        router.show(TrackToast(text: already ? String(localized: "Già nei preferiti") : String(localized: "Aggiunto ai preferiti"),
                               systemImage: "heart.fill", track: track, offersPlaylists: true))
    }

    private var row: some View {
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
        .playbackWarmup(track)
    }

    private var artwork: some View {
        ArtworkView(track: track, size: 50, cornerRadius: 6)
            .overlay {
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: nowPlaying.isPlaying)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.45), in: .rect(cornerRadius: 6))
                }
            }
    }

    /// The download mark (waiting, a filling ring, or the arrow of a saved song), then the length.
    private var trailing: some View {
        HStack(spacing: 8) {
            DownloadIndicator(state: downloads.state(of: track))
            if let duration = track.duration {
                Text(duration.formattedTime)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Large artwork card used in horizontal shelves.
struct TrackCard: View {
    let track: Track
    var size: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: track, size: size, cornerRadius: 14)
            Text(track.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(track.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(.rect)
        .contextMenu { TrackMenu(track: track) }
        .playbackWarmup(track)
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
    /// The playlist they come from, whose Mix then plays.
    var playlist: UUID? = nil
    private var player: PlayerController { .shared }
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.play(tracks, source: source, shuffled: false, playlist: playlist)
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
                player.play(tracks, startAt: Int.random(in: tracks.indices), source: source, shuffled: true,
                            playlist: playlist)
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
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    // Only for actions, so the menus of rows on screen don't redraw with every player change.
    private var player: PlayerController { .shared }
    private var router: AppRouter { .shared }

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
        if !track.primaryArtist.isEmpty {
            Button { router.page = .artist(id: track.artistID, name: track.primaryArtist) } label: {
                Label("Vai all'artista", systemImage: "music.mic")
            }
        }
        if let albumID = track.albumID {
            Button { router.page = .album(id: albumID) } label: {
                Label("Vai all'album", systemImage: "square.stack")
            }
        }
        Button { router.page = .song(track) } label: {
            Label("Informazioni sul brano", systemImage: "info.circle")
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
        if downloads.isDownloaded(track) {
            Button(role: .destructive) { downloads.remove(track) } label: {
                Label("Rimuovi download", systemImage: "trash")
            }
        } else if downloads.isQueued(track) {
            Button(role: .destructive) { downloads.cancel([track]) } label: {
                Label("Annulla download", systemImage: "xmark.circle")
            }
        } else {
            Button { downloads.download(track) } label: {
                Label("Scarica", systemImage: "arrow.down.circle")
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
                Text(player.current?.title ?? String(localized: "Niente in riproduzione"))
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

// MARK: Swipes

/// A sideways drag that starts only when the finger moves more across than up or down, so the list
/// under it still scrolls.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: changed(translation)
        case .ended: ended(translation)
        case .cancelled, .failed: ended(0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }
    }
}

/// The note at the bottom of the screen after a swipe ("Aggiunto ai preferiti"), as Spotify's.
struct TrackToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let systemImage: String
    let track: Track
    /// Tapping it opens the playlists to put the song in.
    var offersPlaylists = false

    static func == (lhs: TrackToast, rhs: TrackToast) -> Bool { lhs.id == rhs.id }
}

private struct TrackToastView: View {
    let toast: TrackToast
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                ArtworkView(track: toast.track, size: 38, cornerRadius: 6)
                Label(toast.text, systemImage: toast.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if toast.offersPlaylists {
                    Text("Cambia")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }
}

/// Shows the swipes' notes on the screen on top: above the mini player over the tabs, at the
/// bottom over the player or a page.
private struct TrackToasts: ViewModifier {
    let presenter: AppRouter.Presenter
    @EnvironmentObject private var router: AppRouter

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                let mini = router.miniPlayerFrame
                let inset = presenter == .root && mini.height > 0 && mini.minY < frame.maxY ? frame.maxY - mini.minY + 10 : 16
                VStack {
                    Spacer()
                    if let toast = router.toast, router.isOnTop(presenter) {
                        TrackToastView(toast: toast) {
                            router.toast = nil
                            if toast.offersPlaylists { router.trackToAdd = toast.track }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, inset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .animation(.spring(duration: 0.35), value: router.toast)
            }
        }
    }
}

extension View {
    func trackToasts(_ presenter: AppRouter.Presenter) -> some View {
        modifier(TrackToasts(presenter: presenter))
    }
}
