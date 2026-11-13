import SwiftUI

/// The Mac's player bar along the bottom of the window, as Apple Music's: shuffle, back, play,
/// forward and repeat; the song with its progress (a click opens the player); then the lyrics, the
/// queue, AirPlay and the volume. In the classic style it is laid out as the common streaming
/// apps' desktop bar: the song on the left (with its favourite), the controls in the middle over
/// the progress and its times, the lyrics, the queue, the output and the volume on the right.
struct MacPlayerBar: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: Library
    @Environment(\.interfaceStyle) private var style
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    /// As tall as Apple Music's: the cover, the song in two lines and its progress.
    static let height: CGFloat = 76

    private var classic: Bool { style == .classic }
    private var tint: Color { classic ? ClassicPalette.accent : accent.color }

    var body: some View {
        if classic { classicBar } else { seaglassBar }
    }

    private var classicBar: some View {
        HStack(spacing: 16) {
            classicSong
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4) {
                transport
                MacClassicScrubber()
                    .disabled(player.current == nil)
            }
            .frame(maxWidth: 560)
            .layoutPriority(1)
            HStack(spacing: 2) {
                button("quote.bubble") { router.openPlayer(on: .lyrics) }
                    .disabled(player.current == nil)
                button("list.bullet") { router.openPlayer(on: .queue) }
                    .disabled(player.current == nil)
                AirPlayButton(activeTint: tint, tint: ClassicPalette.uiPrimaryText)
                    .frame(width: 38, height: 38)
                MacVolumeControl(tint: ClassicPalette.primaryText)
                    .frame(width: 130)
                    .padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 84)
        .foregroundStyle(ClassicPalette.primaryText)
        .buttonStyle(.plain)
    }

    /// The song on the classic bar's left: its cover, its name and artist (a click opens the
    /// player), and the favourite as a green tick.
    private var classicSong: some View {
        HStack(spacing: 12) {
            Button {
                if player.current != nil { router.openPlayer() }
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(track: player.current, size: 56, cornerRadius: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.current?.title ?? String(localized: "Niente in riproduzione"))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let error = player.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(ClassicPalette.secondaryText)
                                .lineLimit(1)
                        } else if let track = player.current {
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(ClassicPalette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(.rect)
            }
            if let track = player.current, !track.isPodcastEpisode {
                let liked = library.isLiked(track)
                Button { library.toggleLike(track) } label: {
                    Image(systemName: liked ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(liked ? ClassicPalette.accent : ClassicPalette.secondaryText)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .accessibilityLabel(liked ? Text("Togli dai preferiti") : Text("Aggiungi ai preferiti"))
            }
        }
    }

    private var seaglassBar: some View {
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
        .foregroundStyle(classic ? ClassicPalette.primaryText : Color.primary)
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
                .foregroundStyle(classic ? ClassicPalette.background : Color.primary)
                .frame(width: 44, height: 44)
                .background {
                    if classic {
                        // White on the dark bar, black on the light one.
                        Circle().fill(ClassicPalette.primaryText)
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
                .foregroundStyle(on ? AnyShapeStyle(tint) : AnyShapeStyle(classic ? ClassicPalette.primaryText : Color.primary))
                .frame(width: 38, height: 38)
                .background(
                    (classic ? ClassicPalette.primaryText : Color.primary).opacity(on ? (classic ? 0.16 : 0.12) : 0),
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

/// The classic bar's progress under its controls, with the time on each side; a click or a drag
/// on it moves the song. Only this redraws as the song plays.
private struct MacClassicScrubber: View {
    @EnvironmentObject private var progress: PlaybackProgress
    @State private var scrubbing: Double?
    @State private var hovering = false

    var body: some View {
        let duration = max(progress.duration, 1)
        let shown = scrubbing ?? min(progress.currentTime, duration)
        HStack(spacing: 8) {
            Text(shown.formattedTime)
                .frame(width: 44, alignment: .trailing)
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let fraction = CGFloat(min(max(shown / duration, 0), 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(ClassicPalette.primaryText.opacity(0.25))
                    Capsule()
                        .fill(hovering || scrubbing != nil ? ClassicPalette.accent : ClassicPalette.primaryText)
                        .frame(width: width * fraction)
                    if hovering || scrubbing != nil {
                        Circle()
                            .fill(ClassicPalette.primaryText)
                            .frame(width: 12, height: 12)
                            .offset(x: width * fraction - 6)
                    }
                }
                .frame(height: 4)
                // Gliding between the player's four ticks a second, at the screen's rate.
                .animation(scrubbing == nil ? .linear(duration: 0.25) : nil, value: shown)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrubbing = Double(min(max(value.location.x / width, 0), 1)) * duration
                        }
                        .onEnded { value in
                            PlayerController.shared.seek(to: Double(min(max(value.location.x / width, 0), 1)) * duration)
                            scrubbing = nil
                        }
                )
            }
            .frame(height: 16)
            .onHover { hovering = $0 }
            Text(progress.duration > 0 ? progress.duration.formattedTime : "--:--")
                .frame(width: 44, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(ClassicPalette.secondaryText)
        .environment(\.layoutDirection, .leftToRight)
    }
}
