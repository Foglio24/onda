import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Opens a given screen at launch, for the screenshots CI takes on a simulator
/// (Tools/Screenshots/run.sh): `-SeaglassScene home | library | settings | search:<query> |
/// artist:<browseId> | album:<browseId> | player:<videoId> | downloads:<videoId> | storage |
/// equalizer | info:<album browseId> | mix | mix:options | mix:edit | home:<videoId>`.
/// `home:<videoId>` records the song's radio as listened to, so the Home has recent songs and mixes.
/// `update:<zip>` (a Mac) installs the app in the zip over the running one, as an update would.
/// `volume:<0…1>` (a Mac) checks the app's volume without changing the output device's volume.
/// `mix` makes two short songs and a playlist of them, and opens their transition in the Mix editor
/// (`mix:options` with the options sheet too, `mix:edit` drawing the volume lines by hand).
/// `downloads` downloads the first songs of a song's radio and shows them downloading;
/// `storage` shows the space they take; `info` plays an album and opens its first song's details;
/// `player` shows a song's radio paused on it; `tempo-live:<videoId>` plays it and says when the
/// tempo panel has its BPM.
/// Launch arguments are never passed in normal use, so this does nothing then.
@MainActor
enum LaunchScene {
    /// Read from the command line only (`-SeaglassScene …`, as CI passes it), never from the saved
    /// defaults: `defaults write` would otherwise keep every Premium feature open for good.
    private static var scene: String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["SeaglassScene"] as? String
    }

    /// A screenshot scene is open: every screen is shown as it is, Premium's included.
    static var isActive: Bool { scene != nil }

    /// Library → Download is opened at launch.
    static var opensDownloads: Bool {
        scene?.hasPrefix("downloads") == true || opensStorage
    }

    /// Library → Download → Spazio occupato is opened at launch.
    static var opensStorage: Bool { scene == "storage" }

    /// Settings → Equalizzatore is opened at launch.
    static var opensEqualizer: Bool { scene == "equalizer" }

    /// Library → the first playlist is opened at launch, pushed inside the library (CI's Mac check
    /// that the player bar stays over pages pushed there).
    static var opensPlaylistInLibrary: Bool { scene == "library-playlist" || opensMixOrder }

    /// `smart:<recent | downloaded | forgottenFavourites>`: that smart collection opened in the library.
    static var opensSmartCollection: SmartCollectionKind? {
        guard let scene, scene.hasPrefix("smart:") else { return nil }
        return SmartCollectionKind(rawValue: String(scene.dropFirst("smart:".count)))
    }

    /// The playlist opened at launch shows "Ordina per il mix" (`mix-order`: songs made here, some
    /// downloaded and some not).
    static var opensMixOrder: Bool { scene == "mix-order" }

    /// Settings → Account is opened at launch, signed in with `-SeaglassAccountToken` (a session CI
    /// makes on the account service for Tools/MacAccountCheck).
    static var opensAccount: Bool { scene == "account" }

    /// `-SeaglassCardProgress 0.55`: the player card stops part of the way, to see it over the app.
    static var playerCardProgress: CGFloat? {
        guard scene != nil, let value = UserDefaults.standard.object(forKey: "SeaglassCardProgress") as? Double
                ?? UserDefaults.standard.string(forKey: "SeaglassCardProgress").flatMap({ Double($0) }) else { return nil }
        return CGFloat(max(0, min(1, value)))
    }

    /// `-SeaglassPanel queue | lyrics | tempo`: the player opens with that panel (the iPad's two columns) or the tempo fader.
    static var playerPanel: String? {
        scene == nil ? nil : UserDefaults.standard.string(forKey: "SeaglassPanel")
    }

    /// `-SeaglassOrientation landscape`: the player is laid out as on an iPad in landscape and scaled
    /// into the screen (an iPad app can't turn itself, nor CI the simulator).
    static var previewsLandscape: Bool {
        scene != nil && UserDefaults.standard.string(forKey: "SeaglassOrientation") == "landscape"
    }

    /// No recording or recognition request runs for these screenshot-only scenes.
    static var opensRecognition: Bool {
        scene == "recognition" || scene?.hasPrefix("recognition:") == true
    }

    static var recognitionPreview: MusicRecognizer.Phase? {
        guard opensRecognition else { return nil }
        if scene == "recognition:listening" { return .listening }
        guard scene == "recognition:result", let track = previewTracks.first else { return .idle }
        return .found(RecognizedSong(track: track, releaseDate: "2026-01-01", label: "Seaglass Records",
                                     genre: "Electronic", composer: "Seaglass Demo", isrc: "ITAAA2600001",
                                     songURL: nil, appleMusicURL: nil, spotifyURL: nil))
    }

    /// Original demo lyrics go through the real lyrics layout, independent of LRCLIB availability.
    static var playerPreviewLyrics: [LyricLine]? {
        guard scene == "player-demo" else { return nil }
        return ["Under a neon sky", "We follow where the water glows", "Every wave becomes a rhythm",
                "Every street will lead us home", "Let the city fade behind us", "Keep the night inside this song",
                "With the tide we move together", "Let the morning come along"].enumerated().map {
            LyricLine(id: $0.offset, time: Double($0.offset) * 22, text: $0.element)
        }
    }

    /// CI captures the Mac layout at two real window sizes, without Accessibility permissions.
    static var macWindowSize: CGSize? {
        guard scene != nil, let value = UserDefaults.standard.string(forKey: "SeaglassWindowSize") else { return nil }
        let parts = value.split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width.isFinite, height.isFinite, (960...2560).contains(width), (640...1600).contains(height) else { return nil }
        return CGSize(width: width, height: height)
    }

    static func apply(select: (AppTab) -> Void) {
        guard let scene = Self.scene else { return }
        let parts = scene.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        let router = AppRouter.shared
        switch parts.first ?? "" {
        case "library", "storage":
            select(.library)
        case "profile":
            // The classic style's profile menu, open over the Home.
            select(.home)
            router.showProfileMenu = true
        case "downloads":
            select(.library)
            Task {
                guard let tracks = try? await InnerTube.shared.radio(for: value), !tracks.isEmpty else { return }
                DownloadManager.shared.downloadAll(Array(tracks.prefix(6)))
            }
        case "settings", "equalizer":
            select(.settings)
        case "account":
            select(.settings)
            if let token = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["SeaglassAccountToken"] as? String {
                Task { await AccountService.shared.checkSignIn(token: token) }
            }
        case "info":
            Task {
                guard let album = try? await InnerTube.shared.album(value), let first = album.tracks.first else { return }
                PlayerController.shared.play(album.tracks, source: album.title)
                router.openPlayer()
                try? await Task.sleep(for: .seconds(1.5))
                router.page = .song(first)
            }
        case "search":
            select(.search)
            router.pendingSearch = value
        case "artist":
            router.page = .artist(id: value, name: "")
        case "album":
            router.page = .album(id: value)
        case "mix":
            select(.library)
            Task {
                let first = Track(videoId: "SeaglassMixDemoA", title: "Neon Drive", artists: ["Seaglass Demo"], duration: 72)
                let second = Track(videoId: "SeaglassMixDemoB", title: "Night Run", artists: ["Seaglass Demo"], duration: 72)
                await Task.detached(priority: .userInitiated) {
                    try? DemoSongs.write(to: Storage.audioFile(for: "SeaglassMixDemoA"), bpm: 124, root: 57, introBars: 0)
                    try? DemoSongs.write(to: Storage.audioFile(for: "SeaglassMixDemoB"), bpm: 128, root: 60, introBars: 8)
                }.value
                let playlist = Library.shared.createPlaylist(named: "Mix demo", tracks: [first, second])
                router.mixTarget = MixTarget(playlistID: playlist.id, opensFirst: true,
                                             options: value == "options" ? .eq : nil,
                                             editing: value == "edit" ? .volume : nil)
            }
        case "player":
            Task {
                guard let tracks = try? await InnerTube.shared.radio(for: value), !tracks.isEmpty else { return }
                PlayerController.shared.cue(tracks, source: "Radio")
                router.openPlayer()
            }
        case "widgets":
            router.showWidgetPreview = true
        case "automix-demo":
            // The Home's AutoMix demo, open over the Home (it makes and mixes its songs as it opens).
            select(.home)
            router.showAutoMixDemo = true
        case "smart":
            select(.library)
        case "smart-check":
            // CI (Tools/FeatureScenes/run.sh): the smart collections' rules on songs played, liked and
            // downloaded here, whatever else the library holds.
            select(.library)
            Task { await smartCheck() }
        case "mix-order":
            // A playlist of songs made here, some downloaded and some not, with "Ordina per il mix" open.
            Task {
                _ = await makeMixOrderPlaylist()
                select(.library)
            }
        case "mix-order-check":
            // CI (Tools/FeatureScenes/run.sh): the order suggested for a playlist analysed in part.
            select(.library)
            Task { await mixOrderCheck() }
        case "automix-demo-check":
            // CI (Tools/FeatureScenes/run.sh): the demo played over a queue that plays, then closed. The
            // queue, its song and its position must be as they were, playing on; a queue that was
            // paused stays paused; the demo's songs never reach the history.
            select(.home)
            Task { await automixDemoCheck(router) }
        case "player-demo":
            PlayerController.shared.cue(previewTracks, source: "Seaglass Demo")
            PlayerController.shared.progress.currentTime = 66
            router.openPlayer()
        case "library-playlist":
            PlayerController.shared.cue(previewTracks, source: "Seaglass Demo")
            let playlist = Library.shared.createPlaylist(named: "Coastal Nights · Demo", tracks: previewTracks)
            if let cover = previewCover(index: 4) { Library.shared.setCover(cover, for: playlist.id) }
            select(.library)
        case "tempo-demo":
            // A song made here at 124 BPM, played from its file: the tempo panel must show its BPM.
            Task {
                let track = Track(videoId: "SeaglassTempoDemo", title: "Tempo demo", artists: ["Seaglass Demo"], duration: 72)
                await Task.detached(priority: .userInitiated) {
                    try? DemoSongs.write(to: Storage.audioFile(for: "SeaglassTempoDemo"), bpm: 124, root: 57, introBars: 0)
                }.value
                PlayerController.shared.play([track], source: "Tempo demo")
                router.openPlayer()
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let measured = PlayerController.shared.songBPM, measured.trackID == track.id {
                        print("tempo-bpm: PASS \(measured.bpm)")
                        return
                    }
                }
                print("tempo-bpm: FAIL")
            }
        case "zoom-change" where ProcessInfo.processInfo.isMacCatalystApp:
            // Settings, then the zoom changed to 150 % while the window is open (as ⌘+ does).
            select(.settings)
            Task {
                try? await Task.sleep(for: .seconds(3))
                func size() -> CGSize {
                    UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first?.bounds.size }.first ?? .zero
                }
                let before = size()
                let report = MacBridge.shared.setZoom(percent: 150) ?? "no plug-in"
                try? await Task.sleep(for: .seconds(1))
                print("zoom: \(report); window \(before) → \(size())")
            }
        case "segue":
            // CI: AutoMix's live transition (see `SegueSession`) between songs made here, 124, 126 and
            // 128 BPM, two minutes each, played from their files from 40 s in; the player's log says
            // what was planned and how the second player kept in step. Live, three songs: the second
            // mix must come too, once the first song brought in is back at its own speed. "off": the
            // live mix turned off; "alac": the songs in ALAC instead of AAC (two songs each).
            Task {
                let first = Track(videoId: "SeaglassSegueDemoA", title: "Segue A", artists: ["Seaglass Demo"], duration: 120)
                let second = Track(videoId: "SeaglassSegueDemoB", title: "Segue B", artists: ["Seaglass Demo"], duration: 120)
                let third = Track(videoId: "SeaglassSegueDemoC", title: "Segue C", artists: ["Seaglass Demo"], duration: 120)
                let live = value.isEmpty
                await Task.detached(priority: .userInitiated) {
                    let alac = value == "alac"
                    try? DemoSongs.write(to: Storage.audioFile(for: "SeaglassSegueDemoA"), bpm: 124, root: 57, introBars: 0,
                                            seconds: 120, alac: alac)
                    try? DemoSongs.write(to: Storage.audioFile(for: "SeaglassSegueDemoB"), bpm: 126, root: 60, introBars: 4,
                                            seconds: 120, alac: alac)
                    if live {
                        try? DemoSongs.write(to: Storage.audioFile(for: "SeaglassSegueDemoC"), bpm: 128, root: 62, introBars: 4,
                                                seconds: 120, alac: alac)
                    }
                }.value
                UserDefaults.standard.set(SongTransition.autoMix.rawValue, forKey: Preferences.songTransition)
                UserDefaults.standard.set(value != "off", forKey: Preferences.liveMix)
                // "Volume uniforme" at work, each song at another gain (0.50, 0.71, 0.40), as real songs
                // are: a mix must hold each at its own.
                UserDefaults.standard.set(true, forKey: Preferences.normalizeVolume)
                await Loudness.shared.remember(6, for: "SeaglassSegueDemoA")
                await Loudness.shared.remember(3, for: "SeaglassSegueDemoB")
                await Loudness.shared.remember(8, for: "SeaglassSegueDemoC")
                let player = PlayerController.shared
                player.play(live ? [first, second, third] : [first, second], source: "Segue demo")
                router.openPlayer()
                try? await Task.sleep(for: .seconds(2))
                player.seek(to: 40)
                let songs = live ? [second, third] : [second]
                var arrived = 0
                for _ in 0..<600 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if arrived < songs.count, player.current?.id == songs[arrived].id {
                        print(String(format: "segue-scene: next song %@ at %.1f s, %@", songs[arrived].title,
                                     player.progress.currentTime, player.autoMixNote ?? "-"))
                        arrived += 1
                    } else if arrived == songs.count, player.progress.currentTime > 65 {
                        // Past where the last mix's file hands on to the song's own (about a minute in).
                        break
                    }
                }
                print(arrived == songs.count ? "segue-scene: done" : "segue-scene: the next song never came")
            }
        case "local":
            // CI (Tools/LocalScene/run.sh): the songs the script put in Documents/Musica, as a person copies
            // them there with Files. What the app finds in them, then each played for a few seconds: the log
            // says, song by song, whether it played and, if not, the player's error.
            select(.library)
            Task {
                let local = LocalMusic.shared
                // A folder chosen as with the Files picker (kept as a bookmark), beside the app's own Musica.
                let picked = Storage.documents.appending(path: "Picked", directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: picked.path) {
                    print("local-scene: picked folder added \(local.add(folder: picked))")
                }
                local.rescan()
                for _ in 0..<120 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !local.scanning, !local.tracks.isEmpty { break }
                }
                print("local-scene: folders \(local.folders.map(\.name)), unreachable \(local.unreachable.count), scanning \(local.scanning)")
                print("local-scene: found \(local.tracks.count) songs")
                for track in local.tracks {
                    let file = Storage.localAudio(for: track)
                    print("local-scene: song \(track.title) | \(track.artist) | \(track.videoId ?? "-") | "
                          + "file \(file?.lastPathComponent ?? "MISSING") | cover \(Storage.localArtwork(for: track) != nil) | "
                          + "\(Int(track.duration ?? 0)) s")
                }
                let player = PlayerController.shared
                for (position, track) in local.tracks.enumerated() {
                    player.play(local.tracks, startAt: position, source: "File locali")
                    if position == 0 { router.openPlayer() }
                    var heard = 0.0
                    for _ in 0..<30 {
                        try? await Task.sleep(for: .milliseconds(500))
                        heard = player.progress.currentTime
                        if heard > 2 || player.errorMessage != nil { break }
                    }
                    print("local-scene: \(heard > 2 ? "PLAYS" : "FAILS") \(track.title): \(String(format: "%.1f", heard)) s, "
                          + "playing \(player.isPlaying), \(player.streamInfo ?? "-"), error \(player.errorMessage ?? "none")")
                }
                // A song whose file has gone: it says so, and nothing is asked of YouTube.
                if let gone = local.tracks.first, let file = Storage.localAudio(for: gone) {
                    try? FileManager.default.removeItem(at: file)
                    player.play([gone], source: "File locali")
                    for _ in 0..<30 {
                        try? await Task.sleep(for: .milliseconds(500))
                        if player.errorMessage != nil { break }
                    }
                    print("local-scene: gone \(gone.title): error \(player.errorMessage ?? "none")")
                }
                player.pause()
                print("local-scene: done")
            }
        case "tempo-live":
            // A real song played from its stream (`value`, a video id): the tempo panel's BPM, as
            // people get it (the log says each step). Live: YouTube may refuse CI's machines.
            Task {
                guard let tracks = try? await InnerTube.shared.radio(for: value), let first = tracks.first else {
                    print("tempo-live: no song")
                    return
                }
                PlayerController.shared.play(tracks, source: "Radio")
                router.openPlayer()
                for _ in 0..<200 {
                    try? await Task.sleep(for: .milliseconds(500))
                    let player = PlayerController.shared
                    if let measured = player.songBPM, measured.trackID == player.current?.id {
                        print("tempo-live: PASS \(measured.bpm) for \(player.current?.title ?? first.title) (\(player.streamInfo ?? "?"))")
                        return
                    }
                }
                print("tempo-live: FAIL (\(PlayerController.shared.streamInfo ?? "no stream"))")
            }
        case "airplay" where ProcessInfo.processInfo.isMacCatalystApp:
            // The AirPlay button of the player bar, clicked: its menu must open by it.
            select(.home)
            PlayerController.shared.cue(previewTracks, source: "Seaglass Demo")
            Task {
                try? await Task.sleep(for: .seconds(3))
                func picker(in view: UIView) -> AVRoutePickerView? {
                    if let picker = view as? AVRoutePickerView { return picker }
                    return view.subviews.lazy.compactMap { picker(in: $0) }.first
                }
                func button(in view: UIView) -> UIButton? {
                    if let button = view as? UIButton { return button }
                    return view.subviews.lazy.compactMap { button(in: $0) }.first
                }
                let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                guard let found = windows.lazy.compactMap({ picker(in: $0) }).first, let window = found.window else {
                    print("airplay: no picker")
                    return
                }
                print("airplay: picker at \(found.convert(found.bounds, to: window)) in a window of \(window.bounds.size)")
                if let control = button(in: found) {
                    control.sendActions(for: .touchUpInside)
                    print("airplay: opened")
                    try? await Task.sleep(for: .seconds(2))
                    print("airplay: windows \(MacBridge.shared.describeWindows())")
                } else {
                    print("airplay: no button")
                }
            }
        case "sidebar-demo":
            select(.home)
            let playlist = Library.shared.createPlaylist(named: "Coastal Nights · Demo", tracks: previewTracks)
            if let cover = previewCover(index: 4) { Library.shared.setCover(cover, for: playlist.id) }
        case "player-close" where ProcessInfo.processInfo.isMacCatalystApp:
            // Exercise the same native button used by a pointer click, without Accessibility
            // automation permissions or a network fixture on the Mac CI runner.
            PlayerController.shared.cue([Track(videoId: nil, title: "Player close check", artists: ["Seaglass"], duration: 180)],
                                        source: "Seaglass")
            router.openPlayer()
            Task {
                func closeButton(in view: UIView) -> UIButton? {
                    if let button = view as? UIButton, button.accessibilityIdentifier == "player.close" { return button }
                    return view.subviews.lazy.compactMap { closeButton(in: $0) }.first
                }
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(100))
                    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                    if let button = windows.lazy.compactMap({ closeButton(in: $0) }).first,
                       let window = button.window {
                        // Wait for the opening animation to finish before issuing the click.
                        try? await Task.sleep(for: .milliseconds(600))
                        let frame = button.convert(button.bounds, to: window)
                        guard frame.minY >= 40, button.isEnabled else {
                            print("player-close: FAIL button overlaps the titlebar")
                            return
                        }
                        let point = CGPoint(x: frame.midX, y: frame.midY)
                        let hit = window.hitTest(point, with: nil)
                        guard hit === button || hit?.isDescendant(of: button) == true else {
                            print("player-close: FAIL button is not hit-testable")
                            return
                        }
                        button.sendActions(for: .touchUpInside)
                        try? await Task.sleep(for: .milliseconds(800))
                        print(router.showPlayer ? "player-close: FAIL cover stayed open" : "player-close: PASS")
                        return
                    }
                }
                print("player-close: FAIL button not found")
            }
        case "update":
            // CI (Tools/Screenshots/mac.sh): installs the Mac app in this zip over the running one, as an
            // update would, and opens it again; what happened goes to the output.
            Task {
                do {
                    let app = try await MacBridge.shared.stage(zip: URL(fileURLWithPath: value), version: AppUpdater.currentVersion)
                    print("update: staged \(app.path)")
                    if let error = MacBridge.shared.install(app: app, relaunch: true) { print("update: \(error)") }
                } catch {
                    print("update: \(error)")
                }
            }
        case "volume":
            // Register two players as in a crossfade; app gain must reach both, and never the device.
            let volume = PlaybackVolume.shared
            let before = volume.value
            let systemBefore = MacBridge.shared.systemVolume
            let first = AVPlayer(), second = AVPlayer()
            volume.register(first)
            volume.setLevel(0.5, for: second)
            let requested = Double(value) ?? 0.5
            volume.set(requested)
            let systemAfter = MacBridge.shared.systemVolume
            let passed = abs(Double(first.volume) - volume.value) < 0.001
                && abs(Double(second.volume) - volume.value * 0.5) < 0.001
                && systemBefore == systemAfter
            print("volume: \(passed ? "PASS" : "FAIL") app \(volume.value), players \(first.volume), \(second.volume)")
            volume.set(before)
        case "home" where !value.isEmpty:
            // The song's radio as if listened to: the Home's recent covers and daily mixes.
            select(.home)
            Task {
                guard let tracks = try? await InnerTube.shared.radio(for: value) else { return }
                for track in tracks.prefix(16).reversed() { Library.shared.recordPlay(track) }
            }
        default:
            select(.home)
        }
    }

    private static func smartCheck() async {
        var failed = false
        func expect(_ condition: Bool, _ text: String) {
            print("smart: \(condition ? "ok" : "FAIL") \(text)")
            if !condition { failed = true }
        }
        let library = Library.shared, log = ListeningLog.shared
        let stamp = Int(Date.now.timeIntervalSince1970)
        func track(_ name: String, _ index: Int) -> Track {
            Track(videoId: "SeaglassSmart\(name)\(stamp)x\(index)", title: "\(name) \(index)", artists: ["Seaglass Demo"], duration: 200)
        }
        // Played: 55 songs, one after the other.
        let played = (1...55).map { track("Played", $0) }
        for song in played { library.recordPlay(song) }
        let recent = SmartCollectionSource.tracks(.recent)
        expect(recent.count == SmartCollections.recentLimit, "Ascoltati di recente holds the last \(SmartCollections.recentLimit) songs (\(recent.count))")
        expect(recent.map(\.id) == played.reversed().prefix(SmartCollections.recentLimit).map(\.id), "the most recent first, as they started")

        // Favourites: one listened to three times, one once, one only for a few seconds twice, one never.
        let liked = (1...4).map { track("Liked", $0) }
        for song in liked.reversed() where !library.isLiked(song) { library.toggleLike(song) }
        func listen(_ song: Track, _ seconds: TimeInterval) {
            log.start(song)
            log.addListened(seconds)
            log.close()
        }
        for _ in 0..<3 { listen(liked[0], 45) }
        listen(liked[1], 45)
        listen(liked[2], 8)
        listen(liked[2], 8)
        let forgotten = SmartCollectionSource.forgotten()
        let ids = forgotten.tracks.map(\.id)
        expect(!ids.contains(liked[0].id), "a favourite listened to three times is not listened to little")
        expect(ids.contains(liked[1].id) && ids.contains(liked[2].id) && ids.contains(liked[3].id),
               "once, a few seconds twice and never are listened to little")
        if let once = ids.firstIndex(of: liked[1].id), let seconds = ids.firstIndex(of: liked[2].id), let never = ids.firstIndex(of: liked[3].id) {
            expect(seconds < never && never < once, "the least listened first, then in the favourites' order (\(seconds), \(never), \(once))")
        }
        expect(forgotten.since != nil, "the rule says since when the log counts")

        // Downloads: one with its file, one whose file has gone.
        let kept = track("Downloaded", 1), gone = track("Downloaded", 2)
        try? DemoSongs.write(to: Storage.audioFile(for: kept.videoId ?? ""), bpm: 120, root: 60, introBars: 0, seconds: 5)
        library.addDownload(gone)
        library.addDownload(kept)
        let downloaded = SmartCollectionSource.tracks(.downloaded).map(\.id)
        expect(downloaded.first == kept.id, "a song downloaded here is in Scaricati, the most recent first")
        expect(!downloaded.contains(gone.id), "a download whose file has gone is not")
        let offline = SmartCollections.availableOffline(liked + [kept], isOnDevice: SmartCollectionSource.isOnDevice).map(\.id)
        expect(offline == [kept.id], "only the song on the device plays offline")

        // Nothing is stored or synced: the library holds what it held, plus what was done here.
        library.removeFromHistory(played)
        for song in liked where library.isLiked(song) { library.toggleLike(song) }
        library.removeDownload(kept)
        library.removeDownload(gone)
        try? FileManager.default.removeItem(at: Storage.audioFile(for: kept.videoId ?? ""))
        print(failed ? "smart: FAIL" : "smart: PASS")
        print("smart: done")
    }

    /// Nine songs: six made here and downloaded (124 to 128 BPM and 100 and 102, louder and quieter,
    /// the last without a beat), two not downloaded and one whose file can't be read, in an order
    /// that mixes badly.
    private static func makeMixOrderPlaylist() async -> Playlist {
        struct Made: Sendable { let id: String, title: String, bpm: Double, root: Int, level: Double, drums: Bool }
        let made = [Made(id: "SeaglassOrderA", title: "Harbour Lights", bpm: 128, root: 57, level: 0.8, drums: true),
                    Made(id: "SeaglassOrderB", title: "Slow Tide", bpm: 100, root: 60, level: 0.45, drums: true),
                    Made(id: "SeaglassOrderC", title: "Night Ferry", bpm: 126, root: 64, level: 0.9, drums: true),
                    Made(id: "SeaglassOrderD", title: "Low Clouds", bpm: 102, root: 62, level: 0.4, drums: true),
                    Made(id: "SeaglassOrderE", title: "Signal Fire", bpm: 124, root: 55, level: 0.7, drums: true),
                    Made(id: "SeaglassOrderF", title: "Still Water", bpm: 90, root: 65, level: 0.3, drums: false)]
        await Task.detached(priority: .userInitiated) {
            for song in made where !Storage.audioFileExists(videoId: song.id) {
                try? DemoSongs.write(to: Storage.audioFile(for: song.id), bpm: song.bpm, root: song.root, introBars: 0,
                                     seconds: 75, level: song.level, drums: song.drums)
            }
            // Not a song at all: its analysis must fail, and the song still stay in the playlist.
            try? Data(repeating: 0x5A, count: 4096).write(to: Storage.audioFile(for: "SeaglassOrderBroken"))
        }.value
        func track(_ id: String, _ title: String) -> Track {
            Track(videoId: id, title: title, artists: ["Seaglass Demo"], duration: 75)
        }
        let songs = made.map { track($0.id, $0.title) }
        let tracks = [songs[0], songs[1], songs[2], track("SeaglassOrderNotHere1", "Open Sea"), songs[3],
                      track("SeaglassOrderBroken", "Broken File"), songs[4], track("SeaglassOrderNotHere2", "Far Shore"), songs[5]]
        if let old = Library.shared.playlists.first(where: { $0.name == "Mix order demo" }) {
            Library.shared.deletePlaylist(old.id)
        }
        return Library.shared.createPlaylist(named: "Mix order demo", tracks: tracks)
    }

    private static func mixOrderCheck() async {
        var failed = false
        func expect(_ condition: Bool, _ text: String) {
            print("mix-order: \(condition ? "ok" : "FAIL") \(text)")
            if !condition { failed = true }
        }
        let playlist = await makeMixOrderPlaylist()
        let before = playlist.tracks.map(\.id)
        let model = MixOrderModel(playlist: playlist)
        model.start()
        for _ in 0..<240 where model.isAnalysing { try? await Task.sleep(for: .milliseconds(500)) }
        let status = model.songs.map(\.status)
        expect(!model.isAnalysing, "the analysis finishes")
        expect(status.filter { $0 == .analysed }.count == 6, "the six songs on the device are analysed (\(status))")
        expect(status.filter { $0 == .notOnDevice }.count == 2, "the two songs not downloaded are not analysed")
        expect(model.songs[5].status == .failed, "the unreadable file is a failed analysis, not a guess")
        expect(model.songs[8].features?.tempo == nil, "the song without a beat has no tempo (not an invented one)")
        for song in model.songs where song.features != nil {
            print("mix-order: \(song.track.title): tempo \(song.features?.tempo.map { String(format: "%.1f", $0) } ?? "-"), "
                  + "key \(song.features?.camelotCode ?? "-"), energy \(song.features?.energy.map { String(format: "%.1f dB", $0) } ?? "-")")
        }
        let features = Dictionary(uniqueKeysWithValues: model.songs.compactMap { song in song.features.map { (song.position, $0) } })

        model.mode = .smooth
        let smooth = model.suggestion
        expect(smooth.placed.count == 6 && smooth.unplaced == [3, 5, 7],
               "Fluido orders the six and keeps the other three at the end in the playlist's order (\(smooth.order))")
        expect(smooth.placed.first == 0, "Fluido starts from the playlist's first song")
        let original = model.originalOrder.filter { features[$0] != nil }
        let costBefore = MixOrder.totalCost(original, features: features), costAfter = MixOrder.totalCost(smooth.placed, features: features)
        expect(costAfter <= costBefore + 1e-9, String(format: "Fluido is smoother than the playlist's order (%.2f, before %.2f)", costAfter, costBefore))
        let summaryBefore = model.summary(of: model.originalOrder), summaryAfter = model.summary(of: smooth.order)
        print("mix-order: Fluido \(smooth.order), tempo \(summaryAfter.tempoClose)/\(summaryAfter.tempoPairs) "
              + "(before \(summaryBefore.tempoClose)/\(summaryBefore.tempoPairs)), keys \(summaryAfter.keysMatch)/\(summaryAfter.keyPairs)")
        expect(summaryAfter.tempoClose >= summaryBefore.tempoClose, "Fluido has at least as many passages at tempo")

        model.mode = .rising
        let rising = model.suggestion
        let energies = rising.placed.compactMap { features[$0]?.energy }
        expect(rising.placed.count == 6 && rising.unplaced == [3, 5, 7], "Energia crescente orders the six (\(rising.order))")
        expect(zip(energies, energies.dropFirst()).allSatisfy { $0 <= $1 },
               "Energia crescente never steps down (\(energies.map { String(format: "%.1f", $0) }))")

        // A passage between the first two songs of the order, heard and stopped.
        if rising.placed.count >= 2 {
            model.togglePassage(from: rising.placed[0], to: rising.placed[1])
            for _ in 0..<120 where model.player.playing == nil && !model.failedPassages.contains(MixOrderModel.key(rising.placed[0], rising.placed[1])) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            expect(model.player.playing == MixOrderModel.key(rising.placed[0], rising.placed[1]), "a passage plays")
            model.player.stop()
        }

        let saved = model.save(named: "Mix order demo · Energia crescente")
        expect(saved?.tracks.count == playlist.tracks.count && Set(saved?.tracks.map(\.id) ?? []) == Set(before),
               "the new playlist has every song (\(saved?.tracks.count ?? 0) of \(playlist.tracks.count))")
        expect(saved?.tracks.map(\.id) == rising.order.map { before[$0] }, "the new playlist is in the suggested order")
        expect(Library.shared.playlist(playlist.id)?.tracks.map(\.id) == before, "the playlist itself is unchanged")
        model.close()
        print(failed ? "mix-order: FAIL" : "mix-order: PASS")
        print("mix-order: done")
    }

    private static func automixDemoCheck(_ router: AppRouter) async {
        let player = PlayerController.shared
        let songs = [Track(videoId: "SeaglassQueueDemoA", title: "Queue A", artists: ["Seaglass Demo"], duration: 72),
                     Track(videoId: "SeaglassQueueDemoB", title: "Queue B", artists: ["Seaglass Demo"], duration: 72)]
        await Task.detached(priority: .userInitiated) {
            try? DemoSongs.write(to: Storage.audioFile(for: "SeaglassQueueDemoA"), bpm: 118, root: 62, introBars: 0)
            try? DemoSongs.write(to: Storage.audioFile(for: "SeaglassQueueDemoB"), bpm: 120, root: 64, introBars: 0)
        }.value
        func wait(_ seconds: Double, until done: () -> Bool) async -> Bool {
            for _ in 0..<Int(seconds * 4) {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return done()
        }
        func state() -> String {
            String(format: "%@ #%d at %.1f s, %@", player.current?.title ?? "-", player.index, player.progress.currentTime,
                   player.isPlaying ? "playing" : "paused")
        }
        var failed = false
        func expect(_ condition: Bool, _ text: String) {
            print("automix-demo: \(condition ? "ok" : "FAIL") \(text)")
            if !condition { failed = true }
        }
        player.play(songs, source: "Queue demo")
        _ = await wait(20) { player.isPlaying && player.progress.currentTime > 1 }
        player.seek(to: 20)
        _ = await wait(10) { player.isPlaying && player.progress.currentTime > 21 }
        let queue = player.queue.map(\.id), index = player.index, time = player.progress.currentTime
        expect(player.isPlaying, "the queue plays before the demo (\(state()))")

        router.showAutoMixDemo = true
        let ready = await wait(180) { AutoMixDemoModel.shown?.phase == .ready }
        expect(ready, "the demo is ready (\(String(describing: AutoMixDemoModel.shown?.phase)))")
        guard ready, let model = AutoMixDemoModel.shown else {
            print("automix-demo: done")
            return
        }
        model.toggle(.plain)
        try? await Task.sleep(for: .seconds(3))
        expect(model.player.playing == "plain" && model.player.position > 1, "the plain listen plays (\(model.player.position) s)")
        expect(!player.isPlaying, "the queue is paused under the demo (\(state()))")
        model.toggle(.autoMix)
        try? await Task.sleep(for: .seconds(3))
        expect(model.player.playing == "autoMix" && model.player.position > 1, "the AutoMix listen plays (\(model.player.position) s)")
        expect(player.queue.map(\.id) == queue && player.index == index, "the queue is unchanged under the demo")
        router.showAutoMixDemo = false
        _ = await wait(8) { player.isPlaying }
        try? await Task.sleep(for: .seconds(1))
        expect(player.queue.map(\.id) == queue && player.index == index, "the queue is the same after the demo (\(state()))")
        expect(player.isPlaying, "the queue plays on after the demo (\(state()))")
        let resumedAt = player.progress.currentTime
        expect(resumedAt >= time - 0.5 && resumedAt < time + 12, String(format: "from where it was: %.1f s, then %.1f s", time, resumedAt))

        // Paused before the demo: still paused after it.
        player.pause()
        let pausedAt = player.progress.currentTime
        router.showAutoMixDemo = true
        _ = await wait(60) { AutoMixDemoModel.shown?.phase == .ready }
        AutoMixDemoModel.shown?.toggle(.autoMix)
        try? await Task.sleep(for: .seconds(2))
        router.showAutoMixDemo = false
        try? await Task.sleep(for: .seconds(2))
        expect(!player.isPlaying && abs(player.progress.currentTime - pausedAt) < 0.6, "a paused queue stays paused (\(state()))")
        let heard = Library.shared.history.contains { AutoMixDemo.songs.map(\.id).contains($0.videoId ?? "") }
        expect(!heard, "the demo's songs are not in the history")
        print(failed ? "automix-demo: FAIL" : "automix-demo: PASS")
        print("automix-demo: done")
    }

    /// Generated locally and used only by explicitly requested demo scenes; no external media.
    private static let previewTracks: [Track] = {
        ["Neon Coast", "Moonlit Avenue", "Tide Pools", "Afterglow"].enumerated().map { index, title in
            let id = "DemoMusic0\(index + 1)"
            if let cover = previewCover(index: index) {
                try? cover.write(to: Storage.artworkFile(for: id), options: .atomic)
            }
            return Track(videoId: id, title: title, artists: ["Seaglass Demo"], album: "Coastal Nights", duration: 204)
        }
    }()

    private static func previewCover(index: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { renderer in
            let context = renderer.cgContext
            let first = UIColor(hue: (0.52 + CGFloat(index) * 0.09).truncatingRemainder(dividingBy: 1),
                                saturation: 0.75, brightness: 0.8, alpha: 1)
            let second = UIColor(hue: (0.85 + CGFloat(index) * 0.06).truncatingRemainder(dividingBy: 1),
                                 saturation: 0.8, brightness: 0.55, alpha: 1)
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: [first.cgColor, second.cgColor] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 512, y: 512), options: [])
            }
            context.setFillColor(UIColor.white.withAlphaComponent(0.14).cgColor)
            context.fillEllipse(in: CGRect(x: 220, y: -80, width: 420, height: 420))
            context.fillEllipse(in: CGRect(x: -160, y: 280, width: 480, height: 480))
            UIImage(systemName: index == 4 ? "sparkles" : "waveform")?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 116, y: 116, width: 280, height: 280))
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}
