import SwiftUI

/// The full-screen player. It doesn't observe the playback position itself: only the scrubber
/// (and the lyrics) redraw as the song plays, not the cover, buttons and glass around them.
struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    /// The card the player sits on (see `PlayerCard`): it follows drags and animates closing.
    @Environment(\.playerCard) private var card
    @AppStorage(Preferences.spatialAudio) private var spatialAudio = true
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    private enum Panel { case artwork, lyrics, queue }

    @State private var panel: Panel = .artwork
    /// A drag down is under way (the card follows it).
    @State private var draggingDown = false
    @State private var showEqualizer = false
    @State private var showTempo = false

    var body: some View {
        GeometryReader { geometry in
            let size = LaunchScene.previewsLandscape
                ? CGSize(width: max(geometry.size.width, geometry.size.height), height: min(geometry.size.width, geometry.size.height))
                : geometry.size
            layout(for: size)
                .frame(width: size.width, height: size.height)
                .scaleEffect(min(1, geometry.size.width / max(size.width, 1)), anchor: .topLeading)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .foregroundStyle(.white)
        .background { background }
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.35), value: panel)
        .sheet(item: router.addToPlaylistBinding(fromPlayer: true)) { track in
            AddToPlaylistSheet(track: track).appEnvironment()
        }
        .sheet(item: router.pageBinding(fromPlayer: true)) { page in
            MusicPageSheet(page: page).appEnvironment()
        }
        .sheet(isPresented: $showEqualizer) {
            NavigationStack {
                EqualizerView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fine") { showEqualizer = false }
                        }
                    }
            }
            .appEnvironment()
        }
        .sheet(isPresented: $showTempo) {
            NavigationStack {
                TempoView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fine") { showTempo = false }
                        }
                    }
            }
            .appEnvironment()
            .presentationDetents([.medium, .large])
        }
        .downloadErrorAlert(isActive: router.showPlayer)
        .trackToasts(.player)
        .background { PlayerKeyboardShortcuts(includesSpace: true) }
        .onAppear {
            // The CI screenshots can open a panel (see `LaunchScene`).
            if let open = LaunchScene.playerPanel {
                if open == "tempo" { showTempo = true } else { panel = open == "queue" ? .queue : .lyrics }
            }
        }
    }

    /// An iPad in landscape (or a wide window): the lyrics or the queue open beside the player
    /// instead of in the cover's place.
    @ViewBuilder private func layout(for size: CGSize) -> some View {
        if size.width >= 900, size.width > size.height, panel != .artwork {
            wideLayout(width: size.width)
        } else {
            stackedLayout
                // On an iPad the player keeps an iPhone's proportions, centred.
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
        }
    }

    /// The player as on an iPhone: the cover (or, with them open, the lyrics or the queue) above
    /// the controls.
    private var stackedLayout: some View {
        VStack(spacing: 16) {
            // Dragging down here closes the player, like the Music app, and dragging up opens the
            // song's details. With the lyrics or the queue open only the header does, so their
            // lists keep scrolling normally.
            VStack(spacing: 16) {
                topBar
                if panel == .artwork {
                    Spacer(minLength: 0)
                    artwork
                    Spacer(minLength: 0)
                    titleRow
                } else {
                    compactHeader
                }
            }
            .contentShape(.rect)
            .simultaneousGesture(dismissDrag)
            if panel != .artwork {
                panelContent
                    .frame(maxHeight: .infinity)
            }
            errorLabel
            PlayerScrubber()
            badges
            controls
            bottomBar
        }
    }

    /// The cover and the controls in a column, the lyrics or the queue beside them.
    private func wideLayout(width: CGFloat) -> some View {
        HStack(spacing: 48) {
            VStack(spacing: 16) {
                VStack(spacing: 16) {
                    topBar
                    Spacer(minLength: 0)
                    artwork
                    Spacer(minLength: 0)
                    titleRow
                }
                .contentShape(.rect)
                .simultaneousGesture(dismissDrag)
                errorLabel
                PlayerScrubber()
                badges
                controls
                bottomBar
            }
            .frame(width: min(520, width * 0.42))
            panelContent
                .padding(.top, 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The lyrics (an episode's chapters and notes) or the queue.
    @ViewBuilder private var panelContent: some View {
        if panel == .lyrics {
            if isEpisode { EpisodeNotesView() } else { LyricsView() }
        } else {
            QueueView()
        }
    }

    @ViewBuilder private var errorLabel: some View {
        if let message = player.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(2)
        }
    }

    /// A drag mostly downwards shrinks the player card towards the mini player as the finger
    /// moves; letting go far enough down, or with a flick, closes it. A drag mostly upwards opens
    /// the song's details, like scrolling down in Spotify's player. Sideways drags are left to the
    /// cover, which tilts with them.
    private var dismissDrag: some Gesture {
        // Global coordinates: the card moves and shrinks with the finger, so local ones would shift.
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                let down = value.translation.height
                guard draggingDown || (down > 0 && down > abs(value.translation.width)) else { return }
                draggingDown = true
                card?.drag(down)
            }
            .onEnded { value in
                guard draggingDown else {
                    let up = -value.translation.height
                    if up > abs(value.translation.width), up > 60 || value.predictedEndTranslation.height < -200,
                       let track = player.current {
                        // An episode's details are its podcast's page.
                        if !track.isPodcastEpisode {
                            router.page = .song(track)
                        } else if let show = track.podcastID, !show.isEmpty {
                            router.page = .podcast(id: show)
                        }
                    }
                    return
                }
                draggingDown = false
                let down = value.translation.height, predicted = value.predictedEndTranslation.height
                if let card {
                    card.release(down, predicted)
                } else if down > 120 || predicted > 260 {
                    dismiss()
                }
            }
    }

    /// The chevron button: the card shrinks back into the mini player.
    private func close() {
        if let card { card.close() } else { dismiss() }
    }

    // MARK: Pieces

    private var background: some View {
        ZStack {
            Color.black
            // Blurred once per song by ArtworkLoader: a live blur this size slowed down opening and closing.
            if let backdrop = player.backdrop {
                Image(uiImage: backdrop)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.55)
            }
            LinearGradient(colors: [player.artworkColor.opacity(0.85), player.artworkColor.opacity(0.4), .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: player.artworkColor)
    }

    private var topBar: some View {
        HStack {
            Button { close() } label: {
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
                Divider()
                sleepTimerMenu
                Button { showEqualizer = true } label: {
                    Label("Equalizzatore", systemImage: "slider.vertical.3")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
    }

    private var sleepTimerMenu: some View {
        Menu {
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minuti") { player.setSleepTimer(minutes: minutes) }
            }
            Button("Fine del brano") { player.stopAtEndOfTrack() }
            if player.sleepTimer != .off {
                Button("Disattiva timer", role: .destructive) { player.cancelSleepTimer() }
            }
        } label: {
            Label("Timer di spegnimento", systemImage: "moon.zzz")
        }
    }

    private var artwork: some View {
        InteractiveArtwork(track: player.current, isPlaying: player.isPlaying) {
            // Double tap likes the song (never un-likes it, like a double tap on a photo).
            if let track = player.current, !track.isPodcastEpisode, !library.isLiked(track) { library.toggleLike(track) }
        }
    }

    /// A podcast episode plays: skips of 15 and 30 seconds, a speed, chapters instead of lyrics, and
    /// no favourites or playlists.
    private var isEpisode: Bool { player.current?.isPodcastEpisode == true }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.current?.title ?? "—")
                    .font(.title2.bold())
                    .lineLimit(1)
                Button {
                    if let track = player.current, track.isPodcastEpisode {
                        if let show = track.podcastID, !show.isEmpty { router.page = .podcast(id: show) }
                    } else if let track = player.current, !track.primaryArtist.isEmpty {
                        router.page = .artist(id: track.artistID, name: track.primaryArtist)
                    }
                } label: {
                    Text(player.current?.artist ?? "")
                        .font(.title3)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !isEpisode {
                addToPlaylistButton
                likeButton
            }
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            ArtworkView(track: player.current, size: 56, cornerRadius: 10)
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
            if !isEpisode {
                addToPlaylistButton
                likeButton
            }
        }
    }

    private var addToPlaylistButton: some View {
        Button {
            router.trackToAdd = player.current
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.title3)
                .frame(width: 40, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(player.current == nil)
    }

    private var likeButton: some View {
        Button {
            if let track = player.current { library.toggleLike(track) }
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.title2)
                .foregroundStyle(isLiked ? Color.pink : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 44)
        }
        .buttonStyle(.plain)
    }

    private var isLiked: Bool {
        guard let track = player.current else { return false }
        return library.isLiked(track)
    }

    /// Format, spatial audio and sleep timer, like the badges in the Music app.
    private var badges: some View {
        HStack(spacing: 8) {
            if let info = player.streamInfo {
                badge { Label(info, systemImage: "waveform") }
            }
            if player.karaokeMode != .off, !isEpisode {
                karaokeBadge
            } else if spatialAudio {
                badge { Label("Audio spaziale", systemImage: "headphones") }
            }
            switch player.sleepTimer {
            case .off:
                EmptyView()
            case .at(let end):
                badge {
                    Label { Text(end, style: .timer) } icon: { Image(systemName: "moon.fill") }
                }
            case .endOfTrack:
                badge { Label("Fine brano", systemImage: "moon.fill") }
            }
        }
        .frame(height: 24)
    }

    @ViewBuilder private var karaokeBadge: some View {
        switch player.karaokeStatus {
        case .preparing(let value, let remaining):
            badge {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text(Self.karaokeProgressText(value, remaining: remaining))
                        .monospacedDigit()
                }
            }
        case .failed:
            badge { Label("Karaoke non riuscito", systemImage: "exclamationmark.triangle") }
        case .ready, .idle:
            badge { Label(player.karaokeMode.title, systemImage: player.karaokeMode.symbol) }
        }
    }

    /// "Karaoke: preparazione 35% · 12 s".
    private static func karaokeProgressText(_ value: Double, remaining: TimeInterval?) -> String {
        guard value > 0 else { return String(localized: "Karaoke: preparazione…") }
        let percent = value.formatted(.percent.precision(.fractionLength(0)))
        var text = String(localized: "Karaoke: preparazione \(percent)")
        if let remaining {
            text += remaining < 60 ? " · \(max(1, Int(remaining))) s" : " · \(Int((remaining / 60).rounded())) min"
        }
        return text
    }

    private func badge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }

    /// Left to right in every language, like the Music app's: back is on the left, forward on the right.
    private var controls: some View {
        Group {
            if isEpisode { episodeControls } else { songControls }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    /// Previous, back 15 seconds, play, forward 30 seconds, next.
    private var episodeControls: some View {
        HStack {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title3).frame(width: 44, height: 44)
            }
            .foregroundStyle(Color.white.opacity(0.7))
            Spacer()
            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 30)).frame(width: 56, height: 56)
            }
            Spacer()
            playButton
            Spacer()
            Button { player.skip(by: 30) } label: {
                Image(systemName: "goforward.30").font(.system(size: 30)).frame(width: 56, height: 56)
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title3).frame(width: 44, height: 44)
            }
            .foregroundStyle(Color.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    private var playButton: some View {
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
    }

    private var songControls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(player.shuffleEnabled ? 0.22 : 0), in: .circle)
            }
            .foregroundStyle(Color.white.opacity(player.shuffleEnabled ? 1 : 0.55))
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 30)).frame(width: 56, height: 56)
            }
            Spacer()
            playButton
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30)).frame(width: 56, height: 56)
            }
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode.symbol)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(player.repeatMode == .off ? 0 : 0.22), in: .circle)
            }
            .foregroundStyle(Color.white.opacity(player.repeatMode == .off ? 0.55 : 1))
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack {
            panelButton(.lyrics, symbol: isEpisode ? "list.bullet.rectangle" : "quote.bubble")
            Spacer()
            if isEpisode { speedMenu } else { karaokeMenu }
            Spacer()
            if !isEpisode {
                tempoButton
                Spacer()
            }
            AirPlayButton(activeTint: accent.color).frame(width: 44, height: 44)
            Spacer()
            panelButton(.queue, symbol: "list.bullet")
        }
    }

    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// "1,5×".
    private static func speedLabel(_ speed: Float) -> String {
        Double(speed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    /// An episode's speed, from half to twice as fast.
    private var speedMenu: some View {
        Menu {
            Picker("Velocità", selection: Binding(get: { player.episodeSpeed },
                                                  set: { player.setEpisodeSpeed($0) })) {
                ForEach(Self.speeds, id: \.self) { speed in
                    Text(Self.speedLabel(speed)).tag(speed)
                }
            }
        } label: {
            Text(Self.speedLabel(player.episodeSpeed))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(player.episodeSpeed == 1 ? 0 : 0.2), in: .circle)
        }
        .buttonStyle(.plain)
    }

    /// The songs' tempo, as a DJ app's fader: the change on the button while there is one.
    private var tempoButton: some View {
        Button { showTempo = true } label: {
            Group {
                if player.songTempo == 0 {
                    Image(systemName: "metronome").font(.title3)
                } else {
                    Text(verbatim: TempoView.percent(player.songTempo, digits: 1))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(width: 44, height: 44)
            .background(Color.white.opacity(player.songTempo == 0 ? 0 : 0.2), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Tempo"))
    }

    /// Karaoke: remove the voice or keep only the voice, at three strengths.
    private var karaokeMenu: some View {
        Menu {
            if case .failed(let message) = player.karaokeStatus {
                Section { Text(message) }
            }
            Picker("Karaoke", selection: Binding(get: { player.karaokeMode },
                                                 set: { player.setKaraoke($0) })) {
                ForEach(KaraokeMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            if player.karaokeMode != .off {
                Picker("Intensità", selection: Binding(get: { player.karaokeAmount },
                                                       set: { player.setKaraokeAmount($0) })) {
                    Text("Leggera").tag(Float(0.5))
                    Text("Media").tag(Float(0.75))
                    Text("Piena").tag(Float(1))
                }
            }
        } label: {
            Image(systemName: player.karaokeMode == .off ? "music.mic" : player.karaokeMode.symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(player.karaokeMode == .off ? 0 : 0.2), in: .circle)
        }
        .buttonStyle(.plain)
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

/// Custom scrubber instead of `Slider`: in the full-screen player the system's dismiss gesture
/// competes with the slider and often swallows the end of the drag, so the seek never happened.
/// A high-priority drag gesture always wins and seeks to wherever the finger lifts.
/// It is the only part of the player that follows the position, four times a second.
private struct PlayerScrubber: View {
    @EnvironmentObject private var progress: PlaybackProgress
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var scrubToken = 0

    var body: some View {
        let duration = max(progress.duration, 1)
        let shown = isScrubbing ? scrubTime : min(progress.currentTime, duration)
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let fraction = min(max(shown / duration, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25))
                    Capsule().fill(Color.white).frame(width: width * CGFloat(fraction))
                }
                .frame(height: isScrubbing ? 12 : 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrubToken += 1
                            isScrubbing = true
                            scrubTime = Double(min(max(value.location.x / width, 0), 1)) * duration
                        }
                        .onEnded { value in
                            let target = Double(min(max(value.location.x / width, 0), 1)) * duration
                            scrubTime = target
                            PlayerController.shared.seek(to: target)
                            // Keep showing the target until the player has caught up.
                            let token = scrubToken
                            Task {
                                try? await Task.sleep(for: .milliseconds(700))
                                if token == scrubToken { isScrubbing = false }
                            }
                        }
                )
            }
            .frame(height: 30)
            .animation(.spring(duration: 0.25), value: isScrubbing)
            HStack {
                Text(shown.formattedTime)
                Spacer()
                Text("-" + max(0, progress.duration - shown).formattedTime)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.6))
        }
        // Time runs left to right in every language (Arabic included), like the Music app's.
        .environment(\.layoutDirection, .leftToRight)
    }
}
