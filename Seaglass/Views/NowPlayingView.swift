import AVFoundation
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// The Mac player's text follows its panel's space; other lists keep their normal typography.
    @Entry var playerTextScale: CGFloat = 1
}

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
    @AppStorage(Preferences.playerVolumeBar) private var playerVolumeBar = true
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @Environment(\.interfaceStyle) private var style

    private enum Panel { case artwork, lyrics, queue }

    @State private var panel: Panel = .artwork
    /// How far the classic player is scrolled down from its top at rest (0 at rest, negative when
    /// pulled down past it).
    @State private var classicPull: CGFloat = 0
    /// The classic style's queue, a sheet over the player as the common streaming apps'.
    @State private var showClassicQueue = false
    @AppStorage(Preferences.lyricsTranslate) private var translateLyrics = false
    /// A drag down is under way (the card follows it).
    @State private var draggingDown = false
    @State private var showEqualizer = false
    @State private var showTempo = false
    @ObservedObject private var account = AccountService.shared
    /// A Premium feature tapped without Premium (where Premium can be bought).
    @State private var paywall: PremiumFeature?

    private static let isMac = ProcessInfo.processInfo.isMacCatalystApp

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
        .sheet(isPresented: $showClassicQueue) {
            classicQueueSheet.appEnvironment()
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
        .premiumPaywall($paywall)
        .downloadErrorAlert(isActive: router.showPlayer)
        .appUpdatePresentation(isActive: true)
        .trackToasts(.player)
        .background { PlayerKeyboardShortcuts(includesSpace: true) }
        .onAppear {
            // The CI screenshots can open a panel (see `LaunchScene`).
            if let open = LaunchScene.playerPanel {
                switch open {
                case "tempo": showTempo = true
                case "below": break // the classic player, scrolled to what's under it
                case "queue": if style == .classic && !Self.isMac { showClassicQueue = true } else { panel = .queue }
                default: panel = .lyrics
                }
            }
            // The Mac's player bar opens the player on the lyrics or the queue.
            if let open = router.playerPanel {
                panel = open == .queue ? .queue : .lyrics
                router.playerPanel = nil
            }
        }
    }

    /// An iPad in landscape (or a wide window): the lyrics or the queue open beside the player
    /// instead of in the cover's place.
    @ViewBuilder private func layout(for size: CGSize) -> some View {
        if Self.isMac {
            macLayout(for: size)
        } else if size.width >= 900, size.width > size.height, panel != .artwork {
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
    @ViewBuilder private var stackedLayout: some View {
        if style == .classic {
            classicStackedLayout
        } else {
            seaglassStackedLayout
        }
    }

    private var seaglassStackedLayout: some View {
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
                    .overlay(alignment: .bottomTrailing) { singControl }
            }
            errorLabel
            PlayerScrubber()
            badges
            controls
            if playerVolumeBar { PlayerVolumeBar() }
            bottomBar
        }
    }

    /// Classic full player, laid out as the common streaming apps': the header stays at the top and
    /// the player under it fills the screen, scrolling down to the lyrics' preview and the next songs;
    /// the lyrics open full screen on the cover's colour, the queue in a sheet. Dragged down by its
    /// header the player follows the finger and closes; pulled down past its top, it closes on release.
    @ViewBuilder private var classicStackedLayout: some View {
        switch panel {
        case .lyrics:
            classicLyricsScreen
        case .artwork, .queue:
            VStack(spacing: 0) {
                // Outside the scroll view, so the drag that closes the player never fights the scrolling.
                classicTopBar
                    .contentShape(.rect)
                    .simultaneousGesture(dismissDrag)
                GeometryReader { geometry in
                    ScrollView(.vertical) {
                        VStack(spacing: 18) {
                            classicPlayerPage
                                .frame(height: geometry.size.height)
                            if !isEpisode { classicLyricsCard }
                            classicUpNextCard
                        }
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                        classicPull = offset
                    }
                    .onScrollPhaseChange { old, new in
                        // Let go after pulling the cover down past the top: the player closes.
                        if old == .interacting, new != .interacting, classicPull < -60 { close() }
                    }
                    // Scrolled, the page fades out under the header (the fade grows with the scroll, so
                    // nothing is faded at rest).
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: min(24, max(0, classicPull)))
                            Color.black
                        }
                    }
                    // The CI screenshots can open it scrolled to the cards under the player.
                    .defaultScrollAnchor(LaunchScene.playerPanel == "below" ? .bottom : .top)
                }
            }
        }
    }

    /// What the classic player shows under its header without scrolling: cover, song, scrubber, controls.
    private var classicPlayerPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            artwork
            Spacer(minLength: 16)
            classicTitleRow
            errorLabel
                .padding(.top, 6)
            PlayerScrubber(classic: true)
                .padding(.top, 14)
            controls
                .padding(.top, 6)
            classicBottomBar
                .padding(.top, 6)
        }
    }

    /// The lyrics full screen, as the common streaming apps show them: the cover's colour behind,
    /// the song at the top, the lines large on the left, the scrubber and play at the bottom.
    private var classicLyricsScreen: some View {
        VStack(spacing: 12) {
            classicPanelHeader(title: player.current?.title ?? "", subtitle: player.current?.artist ?? "")
            Group {
                if isEpisode { EpisodeNotesView() } else { LyricsView() }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) { singControl }
            PlayerScrubber(classic: true)
            HStack {
                Spacer()
                playButton
                Spacer()
            }
        }
    }

    /// A panel's header in the classic player: back to the player on the left, two centred lines.
    private func classicPanelHeader(title: String, subtitle: String) -> some View {
        HStack {
            Button { withAnimation { panel = .artwork } } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("Chiudi"))
            Spacer(minLength: 8)
            VStack(spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // As wide as the chevron, so the two lines stay centred.
            Color.clear.frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    /// Under the classic player: the next three songs, and the whole queue a tap away.
    @ViewBuilder private var classicUpNextCard: some View {
        let next = Array(player.upcoming.prefix(3))
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Prossimi brani")
                        .font(.headline.weight(.bold))
                    Spacer(minLength: 8)
                    Button { showClassicQueue = true } label: {
                        Text("Apri la coda")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(next) { entry in
                    let track = entry.track
                    HStack(spacing: 12) {
                        ArtworkView(track: track, size: 44, cornerRadius: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.7))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                    .onTapGesture { showClassicQueue = true }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.1), in: .rect(cornerRadius: 12))
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
                if playerVolumeBar { PlayerVolumeBar() }
                bottomBar
            }
            .frame(width: min(520, width * 0.42))
            panelContent
                .padding(.top, 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) { singControl }
        }
    }

    /// The karaoke beside the lyrics, as Apple Music's Sing (iPhone and iPad; a Mac keeps its menu).
    @ViewBuilder private var singControl: some View {
        if panel == .lyrics, !isEpisode {
            SingControl(paywall: $paywall)
                .padding(.trailing, 2)
                .padding(.bottom, 12)
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
                    // In the classic player a drag up scrolls to the lyrics and the next songs.
                    guard style != .classic || Self.isMac else { return }
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
        if let card {
            card.close()
        } else if Self.isMac {
            router.closePlayerNow()
        } else {
            dismiss()
        }
    }

    // MARK: Pieces

    @ViewBuilder private var background: some View {
        if style == .classic {
            // From the cover's colour at the top down to the page's black, with nothing blurred behind.
            ZStack {
                ClassicPalette.background
                if panel == .lyrics {
                    // The lyrics sit on the cover's colour itself.
                    player.artworkColor.mix(with: .black, by: 0.2)
                } else {
                    LinearGradient(colors: [player.artworkColor.mix(with: .black, by: 0.15), player.artworkColor.mix(with: .black, by: 0.6),
                                            ClassicPalette.background],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.8), value: player.artworkColor)
        } else {
            seaglassBackground
        }
    }

    private var seaglassBackground: some View {
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
                moreMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
    }

    /// Classic header: just the source between chevron and ···, as the common streaming apps.
    private var classicTopBar: some View {
        HStack {
            Button { close() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer(minLength: 8)
            Text(player.source)
                .font(.footnote.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                moreMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
    }

    private var classicTitleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.current?.title ?? "—")
                    .font(.title.bold())
                    .lineLimit(1)
                Button {
                    if let track = player.current, track.isPodcastEpisode {
                        if let show = track.podcastID, !show.isEmpty { router.page = .podcast(id: show) }
                    } else if let track = player.current, !track.primaryArtist.isEmpty {
                        router.page = .artist(id: track.artistID, name: track.primaryArtist)
                    }
                } label: {
                    Text(player.current?.artist ?? "")
                        .font(.body)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            if !isEpisode { likeButton }
        }
    }

    /// Under the controls: where the sound goes (its name in green when it isn't the iPhone), share,
    /// and the queue.
    private var classicBottomBar: some View {
        HStack(spacing: 4) {
            ClassicOutputLabel()
            Spacer()
            // Tempo (a song's speed with its key kept), or an episode's speed.
            if isEpisode { speedMenu } else { tempoButton }
            if let url = player.current?.shareURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
            Button { showClassicQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Coda"))
        }
    }

    /// The lyrics' preview under the classic player, as the common streaming apps': on the cover's
    /// colour, the lines around the one being sung (sung ones white, the next ones dark), the
    /// translation's switch, and "Mostra testo", which opens them full screen (as a tap on the card).
    private var classicLyricsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Anteprima del testo")
                    .font(.headline.weight(.bold))
                Spacer(minLength: 8)
                Button {
                    guard account.unlocks(.lyricsTranslation) else {
                        paywall = .lyricsTranslation
                        return
                    }
                    translateLyrics.toggle()
                } label: {
                    Image(systemName: "translate")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(translateLyrics ? 0.45 : 0.22), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(translateLyrics ? "Nascondi traduzione" : "Mostra traduzione")
            }
            // The CI's demo song has its lyrics from `LaunchScene`, as the lyrics page does.
            ClassicLyricsPeek(lyrics: LaunchScene.playerPreviewLyrics.map { .synced($0) } ?? player.lyrics,
                              translates: translateLyrics && account.unlocks(.lyricsTranslation))
            Button { withAnimation { panel = .lyrics } } label: {
                Text("Mostra testo")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.white, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(player.artworkColor.mix(with: .white, by: 0.08), in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture { withAnimation { panel = .lyrics } }
    }

    /// The classic queue's sheet: the title and what plays, the song playing, the next ones with their
    /// handles, and shuffle and the sleep timer at the bottom.
    private var classicQueueSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Coda")
                    .font(.title.bold())
                Text("In riproduzione: **\(player.source)**")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 4)
            QueueView()
                .frame(maxHeight: .infinity)
            HStack(spacing: 12) {
                Button { player.toggleShuffle() } label: {
                    classicQueueAction("Riproduzione casuale", symbol: "shuffle", on: player.shuffleEnabled)
                }
                .buttonStyle(.plain)
                Menu {
                    sleepTimerOptions
                } label: {
                    classicQueueAction("Timer", symbol: "timer", on: player.sleepTimer != .off)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(white: 0.13))
    }

    private func classicQueueAction(_ title: LocalizedStringKey, symbol: String, on: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(on ? ClassicPalette.accent : Color.white)
        .frame(width: 130, height: 72)
        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
    }

    /// The song's actions, the sleep timer and the equalizer.
    @ViewBuilder private var moreMenu: some View {
        if let track = player.current { TrackMenu(track: track, inPlayer: true) }
        Divider()
        sleepTimerMenu
        Button { showEqualizer = true } label: {
            Label("Equalizzatore", systemImage: "slider.vertical.3")
        }
    }

    private var sleepTimerMenu: some View {
        Menu {
            sleepTimerOptions
        } label: {
            Label("Timer di spegnimento", systemImage: "moon.zzz")
        }
    }

    @ViewBuilder private var sleepTimerOptions: some View {
        ForEach([15, 30, 45, 60], id: \.self) { minutes in
            Button("\(minutes) minuti") { player.setSleepTimer(minutes: minutes) }
        }
        Button("Fine del brano") { player.stopAtEndOfTrack() }
        if player.sleepTimer != .off {
            Button("Disattiva timer", role: .destructive) { player.cancelSleepTimer() }
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
            Image(systemName: style == .classic ? (isLiked ? "checkmark.circle.fill" : "plus.circle") : (isLiked ? "heart.fill" : "heart"))
                .font(.title2)
                .foregroundStyle(isLiked ? (style == .classic ? ClassicPalette.accent : Color.pink) : Color.white)
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
            .styledSurface(in: .capsule)
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
                    ProgressView().controlSize(.large).tint(style == .classic ? .black : .white)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 44))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 76, height: 76)
            .modifier(PlayButtonLook(classic: style == .classic))
        }
    }

    private var songControls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                toggleLook("shuffle", on: player.shuffleEnabled)
            }
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
                toggleLook(player.repeatMode.symbol, on: player.repeatMode != .off)
            }
        }
        .buttonStyle(.plain)
    }

    /// Shuffle or repeat: on, a light disc behind it (Seaglass) or green with a dot under it (classic).
    @ViewBuilder private func toggleLook(_ symbol: String, on: Bool) -> some View {
        if style == .classic {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.title3)
                Circle()
                    .frame(width: 4, height: 4)
                    .opacity(on ? 1 : 0)
            }
            .frame(width: 44, height: 44)
            .foregroundStyle(on ? ClassicPalette.accent : Color.white.opacity(0.7))
        } else {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(on ? 0.22 : 0), in: .circle)
                .foregroundStyle(Color.white.opacity(on ? 1 : 0.55))
        }
    }

    private var bottomBar: some View {
        HStack {
            panelButton(.lyrics, symbol: isEpisode ? "list.bullet.rectangle" : "quote.bubble")
            Spacer()
            // A song's karaoke is beside its lyrics (see `singControl`), as Apple Music's Sing.
            if isEpisode {
                speedMenu
                Spacer()
            }
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
        Button {
            if account.unlocks(.tempo) { showTempo = true } else { paywall = .tempo }
        } label: {
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
            .overlay(alignment: .topTrailing) {
                if !account.unlocks(.tempo) { PremiumLock().offset(x: -2, y: 4) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Tempo"))
    }

    /// Karaoke: remove the voice or keep only the voice, at three strengths. Without Premium
    /// (where it can be bought) the button explains Premium instead.
    @ViewBuilder private var karaokeMenu: some View {
        if account.unlocks(.karaoke) {
            karaokeChoices
        } else {
            Button { paywall = .karaoke } label: {
                Image(systemName: "music.mic")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) { PremiumLock().offset(x: -2, y: 4) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Karaoke"))
        }
    }

    private var karaokeChoices: some View {
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

    // MARK: Mac

    /// On a Mac, as Apple Music's: the cover, the song and its controls in a column in the middle
    /// (on the left, with the lyrics or the queue open beside it), and the rest in glass at the
    /// corners: closing at the top left, AirPlay and the volume at the top right, karaoke, tempo,
    /// lyrics and queue at the bottom right.
    private func macLayout(for size: CGSize) -> some View {
        let spacing = min(64, max(28, size.width * 0.045))
        let columnWidth = panel == .artwork
            ? min(620, size.width * 0.68)
            : min(540, (size.width - spacing) * 0.48)
        let panelWidth = max(1, size.width - columnWidth - spacing)
        let panelHeight = max(1, size.height - 120)
        let textScale = min(1.6, max(0.85, min(panelWidth / 420, panelHeight / 440)))
        return HStack(spacing: spacing) {
            macColumn(width: columnWidth, height: size.height)
            if panel != .artwork {
                panelContent
                    .environment(\.playerTextScale, textScale)
                    .padding(.top, 60)
                    .padding(.bottom, 60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            macCapsule {
                MacPlayerCloseButton(action: close)
                    .frame(width: 44, height: 44)
            }
        }
        .overlay(alignment: .topTrailing) {
            macCapsule {
                AirPlayButton(activeTint: accent.color).frame(width: 36, height: 36)
                MacVolumeControl()
                    .frame(width: 130)
                    .padding(.trailing, 8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            macCapsule {
                if isEpisode { speedMenu } else { karaokeMenu }
                if !isEpisode { tempoButton }
                panelButton(.lyrics, symbol: isEpisode ? "list.bullet.rectangle" : "quote.bubble")
                panelButton(.queue, symbol: "list.bullet")
            }
        }
    }

    private func macColumn(width: CGFloat, height: CGFloat) -> some View {
        // Leave room for the controls and corner capsules even at the minimum window height.
        // In a larger window the cover grows with it, instead of stopping at 320 points.
        let verticalReserve: CGFloat = player.errorMessage == nil ? 420 : 468
        let coverSize = min(560, width, max(100, height - verticalReserve))
        return VStack(spacing: 14) {
            artwork
                .frame(width: coverSize, height: coverSize)
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.current?.title ?? "—")
                            .font(.system(size: min(28, max(20, width * 0.055)), weight: .bold))
                            .lineLimit(1)
                        Button {
                            if let track = player.current, track.isPodcastEpisode {
                                if let show = track.podcastID, !show.isEmpty { router.page = .podcast(id: show) }
                            } else if let track = player.current, !track.primaryArtist.isEmpty {
                                router.page = .artist(id: track.artistID, name: track.primaryArtist)
                            }
                        } label: {
                            Text(macSubtitle)
                                .font(.system(size: min(22, max(17, width * 0.043))))
                                .foregroundStyle(Color.white.opacity(0.7))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 8)
                    if !isEpisode { likeButton }
                    Menu {
                        moreMenu
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                }
                PlayerScrubber()
                badges
                controls
                errorLabel
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 56)
        .padding(.bottom, 60)
        .frame(width: width, height: height)
    }

    /// "Artist — Album", as Apple Music's player.
    private var macSubtitle: String {
        guard let track = player.current else { return "" }
        if let album = track.album, !album.isEmpty, !track.isPodcastEpisode { return "\(track.artist) — \(album)" }
        return track.artist
    }

    private func macCapsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 6)
            .frame(height: 46)
            .glassEffect(.regular.interactive(), in: .capsule)
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

/// A native control keeps the Mac's close action separate from titlebar dragging and SwiftUI's
/// card gestures. The identifier also lets the Mac smoke check exercise the same action as a click.
private struct MacPlayerCloseButton: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        configuration.baseForegroundColor = .white
        button.configuration = configuration
        button.accessibilityLabel = String(localized: "Chiudi player")
        button.accessibilityIdentifier = "player.close"
        button.addAction(UIAction { _ in context.coordinator.action() }, for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }
}

/// Custom scrubber instead of `Slider`: in the full-screen player the system's dismiss gesture
/// competes with the slider and often swallows the end of the drag, so the seek never happened.
/// A high-priority drag gesture always wins and seeks to wherever the finger lifts.
/// It is the only part of the player that follows the position, four times a second.
private struct PlayerScrubber: View {
    var classic = false
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
                    Capsule().fill(Color.white.opacity(classic ? 0.3 : 0.25))
                    transitionMarkView(width: width, duration: duration, shown: shown)
                    Capsule().fill(Color.white).frame(width: max(classic ? 8 : 0, width * CGFloat(fraction)))
                    if classic {
                        Circle()
                            .fill(Color.white)
                            .frame(width: isScrubbing ? 16 : 12, height: isScrubbing ? 16 : 12)
                            .offset(x: max(0, width * CGFloat(fraction) - (isScrubbing ? 8 : 6)))
                    }
                }
                .frame(height: isScrubbing ? 12 : (classic ? 4 : 6))
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
            .animation(.easeInOut(duration: 0.6), value: progress.transitionMark)
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

    /// Where the transition into the next song will happen, shown once it is less than a minute
    /// away (Settings › Riproduzione), under the part already played.
    @ViewBuilder private func transitionMarkView(width: CGFloat, duration: TimeInterval, shown: TimeInterval) -> some View {
        if let mark = progress.transitionMark, shown >= mark.start - Self.markLead, mark.end > mark.start {
            let start = CGFloat(min(max(mark.start / duration, 0), 1)) * width
            let end = CGFloat(min(max(mark.end / duration, 0), 1)) * width
            Capsule()
                .fill(LinearGradient(colors: [Color.cyan, Color.purple], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(4, end - start))
                .offset(x: start)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    /// How long before the transition its mark appears.
    private static let markLead: TimeInterval = 60
}

/// Four lines inside the classic lyrics' preview, from the one before the line being sung: sung
/// lines white, the next ones dark, as the common streaming apps; with their translation under them
/// when it's on and ready. It ticks with the song (its own view, so the player around it doesn't).
private struct ClassicLyricsPeek: View {
    let lyrics: LyricsState
    let translates: Bool
    @EnvironmentObject private var progress: PlaybackProgress
    @EnvironmentObject private var translator: LyricsTranslator

    var body: some View {
        switch lyrics {
        case .synced(let lines):
            let current = lines.lastIndex(where: { $0.time <= progress.currentTime + 0.25 })
            let start = max(0, (current ?? 0) - 1)
            let end = min(lines.count, start + 4)
            let translations = translates && translator.lines == lines ? translator.translations : [:]
            VStack(alignment: .leading, spacing: 10) {
                ForEach(lines[start..<end]) { line in
                    let sung = current.map { line.id <= lines[$0].id } ?? false
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title2.weight(.bold))
                        if let translated = translations[line.id] {
                            Text(translated)
                                .font(.body.weight(.semibold))
                                .opacity(0.8)
                        }
                    }
                    .foregroundStyle(sung ? Color.white : Color.black.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: current)
        case .plain(let text):
            Text(text)
                .font(.title2.weight(.bold))
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .loading, .idle:
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        case .unavailable:
            Text("Testo non disponibile")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        }
    }
}

/// Where the sound goes, under the classic player's controls: the output button and, beside it in
/// green, the name of the headphones or speaker it plays on (nothing when it's the iPhone's own).
private struct ClassicOutputLabel: View {
    @State private var name: String? = ClassicOutputLabel.currentName()

    var body: some View {
        HStack(spacing: 0) {
            AirPlayButton(activeTint: ClassicPalette.accent)
                .frame(width: 44, height: 44)
            if let name {
                Text(name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ClassicPalette.accent)
                    .lineLimit(1)
            }
        }
        // iOS posts route changes on its own thread.
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in
            name = Self.currentName()
        }
    }

    /// The output the sound goes to, unless it's the iPhone's speaker or earpiece.
    private static func currentName() -> String? {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first,
              port.portType != .builtInSpeaker, port.portType != .builtInReceiver else { return nil }
        return port.portName
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The play button: a glass disc in Seaglass's style; white with a black symbol in the classic one.
private struct PlayButtonLook: ViewModifier {
    let classic: Bool

    func body(content: Content) -> some View {
        if classic {
            content
                .foregroundStyle(.black)
                .tint(.black)
                .scaleEffect(0.8)
                .background(Circle().fill(.white).padding(4))
        } else {
            content.glassEffect(.regular.interactive(), in: .circle)
        }
    }
}
