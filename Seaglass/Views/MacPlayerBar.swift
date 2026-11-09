import SwiftUI

/// The Mac's player bar along the bottom of the window, as Apple Music's: shuffle, back, play,
/// forward and repeat; the song with its progress (a click opens the player); then the lyrics, the
/// queue, AirPlay and the volume.
struct MacPlayerBar: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var router: AppRouter
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    var body: some View {
        HStack(spacing: 16) {
            transport
            song
            HStack(spacing: 2) {
                button("quote.bubble") { router.openPlayer(on: .lyrics) }
                    .disabled(player.current == nil)
                button("list.bullet") { router.openPlayer(on: .queue) }
                    .disabled(player.current == nil)
                AirPlayButton(activeTint: accent.color, tint: .label)
                    .frame(width: 32, height: 32)
                MacVolumeControl(tint: .primary)
                    .frame(width: 120)
                    .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 14)
        .buttonStyle(.plain)
    }

    /// Left to right in every language, as the player's.
    private var transport: some View {
        HStack(spacing: 4) {
            button("shuffle", on: player.shuffleEnabled) { player.toggleShuffle() }
            button("backward.fill") { player.previous() }
            Button { player.togglePlayPause() } label: {
                Group {
                    if player.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .font(.title2)
                .frame(width: 36, height: 36)
                .contentShape(.rect)
            }
            button("forward.fill") { player.next() }
            button(player.repeatMode.symbol, on: player.repeatMode != .off) { player.cycleRepeat() }
        }
        .disabled(player.current == nil)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var song: some View {
        Button {
            if player.current != nil { router.openPlayer() }
        } label: {
            HStack(spacing: 10) {
                ArtworkView(track: player.current, size: 36, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.current?.title ?? String(localized: "Niente in riproduzione"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if player.current != nil {
                        MacBarProgress()
                            .padding(.top, 3)
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Artist — Album", or why the song can't play.
    private var subtitle: String? {
        if let error = player.errorMessage { return error }
        guard let track = player.current else { return nil }
        if let album = track.album, !album.isEmpty, !track.isPodcastEpisode { return "\(track.artist) — \(album)" }
        return track.artist
    }

    private func button(_ symbol: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(on ? 0.12 : 0), in: .circle)
                .contentShape(.rect)
        }
    }
}

/// The song's progress under its name in the player bar: only this redraws as it plays.
private struct MacBarProgress: View {
    @EnvironmentObject private var progress: PlaybackProgress

    var body: some View {
        let fraction = progress.duration > 0 ? min(max(progress.currentTime / progress.duration, 0), 1) : 0
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(Color.primary.opacity(0.6)).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
}
