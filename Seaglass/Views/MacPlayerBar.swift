import SwiftUI

/// The Mac's player bar along the bottom of the window, as Apple Music's: shuffle, back, play,
/// forward and repeat; the song with its progress (a click opens the player); then the lyrics, the
/// queue, AirPlay and the volume. In the classic style it is flat and green, with a white play
/// button, like the common streaming apps' desktop chrome.
struct MacPlayerBar: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var router: AppRouter
    @Environment(\.interfaceStyle) private var style
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    /// As tall as Apple Music's: the cover, the song in two lines and its progress.
    static let height: CGFloat = 76

    private var classic: Bool { style == .classic }
    private var tint: Color { classic ? ClassicPalette.accent : accent.color }

    var body: some View {
        HStack(spacing: 16) {
            transport
            song
            HStack(spacing: 2) {
                button("quote.bubble") { router.openPlayer(on: .lyrics) }
                    .disabled(player.current == nil)
                button("list.bullet") { router.openPlayer(on: .queue) }
                    .disabled(player.current == nil)
                AirPlayButton(activeTint: tint, tint: classic ? .white : .label)
                    .frame(width: 38, height: 38)
                MacVolumeControl(tint: classic ? .white : .primary)
                    .frame(width: 150)
                    .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: Self.height)
        .foregroundStyle(classic ? Color.white : Color.primary)
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
                            .tint(classic ? .black : .primary)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .font(.title)
                .foregroundStyle(classic ? Color.black : Color.primary)
                .frame(width: 44, height: 44)
                .background {
                    if classic {
                        Circle().fill(Color.white)
                    }
                }
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
                ArtworkView(track: player.current, size: 54, cornerRadius: classic ? 4 : 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.current?.title ?? String(localized: "Niente in riproduzione"))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(classic ? ClassicPalette.secondaryText : Color.secondary)
                            .lineLimit(1)
                    }
                    if player.current != nil {
                        MacBarProgress(classic: classic)
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
                .font(.title3.weight(.medium))
                .foregroundStyle(on ? AnyShapeStyle(tint) : AnyShapeStyle(classic ? Color.white : Color.primary))
                .frame(width: 38, height: 38)
                .background(
                    (classic ? Color.white : Color.primary).opacity(on ? (classic ? 0.16 : 0.12) : 0),
                    in: .circle
                )
                .contentShape(.rect)
        }
    }
}

/// The song's progress under its name in the player bar: only this redraws as it plays.
private struct MacBarProgress: View {
    var classic = false
    @EnvironmentObject private var progress: PlaybackProgress

    var body: some View {
        let fraction = progress.duration > 0 ? min(max(progress.currentTime / progress.duration, 0), 1) : 0
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(classic ? 0.25 : 0.15))
                Capsule()
                    .fill(classic ? ClassicPalette.accent : Color.primary.opacity(0.6))
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 3)
        .environment(\.layoutDirection, .leftToRight)
    }
}
