import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var progress: PlaybackProgress
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss

    private enum Panel { case artwork, lyrics, queue }

    @State private var panel: Panel = .artwork
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 18) {
            topBar
            if panel == .artwork {
                Spacer(minLength: 0)
                artwork
                Spacer(minLength: 0)
                titleRow
            } else {
                compactHeader
                Group {
                    if panel == .lyrics { LyricsView() } else { QueueView() }
                }
                .frame(maxHeight: .infinity)
            }
            if let message = player.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(2)
            }
            scrubber
            controls
            bottomBar
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .foregroundStyle(.white)
        .background { background }
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.35), value: panel)
    }

    // MARK: Pieces

    private var background: some View {
        ZStack {
            Color.black
            LinearGradient(colors: [player.artworkColor, player.artworkColor.opacity(0.55), .black],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: player.artworkColor)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("IN RIPRODUZIONE DA")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(player.source)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                if let track = player.current { TrackMenu(track: track, inPlayer: true) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
    }

    private var artwork: some View {
        ArtworkView(track: player.current, cornerRadius: 18, highRes: true)
            .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
            .scaleEffect(player.isPlaying ? 1 : 0.88)
            .animation(.spring(duration: 0.45, bounce: 0.25), value: player.isPlaying)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.current?.title ?? "—")
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(player.current?.artist ?? "")
                    .font(.title3)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            likeButton
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            ArtworkView(track: player.current, size: 56, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Text(player.current?.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            likeButton
        }
    }

    private var likeButton: some View {
        Button {
            if let track = player.current { library.toggleLike(track) }
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.title2)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    private var isLiked: Bool {
        guard let track = player.current else { return false }
        return library.isLiked(track)
    }

    private var scrubber: some View {
        let shown = isScrubbing ? scrubTime : progress.currentTime
        return VStack(spacing: 4) {
            Slider(
                value: Binding(get: { shown }, set: { value in
                    scrubTime = value
                    isScrubbing = true
                }),
                in: 0...max(progress.duration, 1),
                onEditingChanged: { editing in
                    if !editing && isScrubbing {
                        player.seek(to: scrubTime)
                        isScrubbing = false
                    }
                }
            )
            .tint(.white)
            HStack {
                Text(shown.formattedTime)
                Spacer()
                Text("-" + max(0, progress.duration - shown).formattedTime)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.6))
        }
    }

    private var controls: some View {
        HStack {
            Button { player.shuffleUpcoming() } label: {
                Image(systemName: "shuffle").font(.title3).frame(width: 44, height: 44)
            }
            .foregroundStyle(Color.white.opacity(0.7))
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 30)).frame(width: 56, height: 56)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 44))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 76, height: 76)
                .glassEffect(.regular.interactive(), in: .circle)
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30)).frame(width: 56, height: 56)
            }
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode.symbol).font(.title3).frame(width: 44, height: 44)
            }
            .foregroundStyle(Color.white.opacity(player.repeatMode == .off ? 0.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack {
            panelButton(.lyrics, symbol: "quote.bubble")
            Spacer()
            AirPlayButton().frame(width: 44, height: 44)
            Spacer()
            panelButton(.queue, symbol: "list.bullet")
        }
    }

    private func panelButton(_ target: Panel, symbol: String) -> some View {
        Button {
            panel = panel == target ? .artwork : target
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(panel == target ? 0.2 : 0), in: .circle)
        }
        .buttonStyle(.plain)
    }
}
