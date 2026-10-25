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

struct TrackRow: View {
    let track: Track
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var downloads: DownloadManager

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
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
        .contextMenu { TrackMenu(track: track) }
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
    }
}

/// The actions available on every song, used in context menus and in the player's "…" menu.
struct TrackMenu: View {
    let track: Track
    var inPlayer = false
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager

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
                Label("Non mi piace più", systemImage: "heart.slash")
            } else {
                Label("Mi piace", systemImage: "heart")
            }
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
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemPink
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
