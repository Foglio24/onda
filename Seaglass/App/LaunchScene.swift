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
    private static var scene: String? { UserDefaults.standard.string(forKey: "SeaglassScene") }

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
    static var opensPlaylistInLibrary: Bool { scene == "library-playlist" }

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
            if let token = UserDefaults.standard.string(forKey: "SeaglassAccountToken") {
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
                    try? Self.writeDemoSong(to: Storage.audioFile(for: "SeaglassMixDemoA"), bpm: 124, root: 57, introBars: 0)
                    try? Self.writeDemoSong(to: Storage.audioFile(for: "SeaglassMixDemoB"), bpm: 128, root: 60, introBars: 8)
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
                    try? Self.writeDemoSong(to: Storage.audioFile(for: "SeaglassTempoDemo"), bpm: 124, root: 57, introBars: 0)
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
                    try? Self.writeDemoSong(to: Storage.audioFile(for: "SeaglassSegueDemoA"), bpm: 124, root: 57, introBars: 0,
                                            seconds: 120, alac: alac)
                    try? Self.writeDemoSong(to: Storage.audioFile(for: "SeaglassSegueDemoB"), bpm: 126, root: 60, introBars: 4,
                                            seconds: 120, alac: alac)
                    if live {
                        try? Self.writeDemoSong(to: Storage.audioFile(for: "SeaglassSegueDemoC"), bpm: 128, root: 62, introBars: 4,
                                                seconds: 120, alac: alac)
                    }
                }.value
                UserDefaults.standard.set(SongTransition.autoMix.rawValue, forKey: Preferences.songTransition)
                UserDefaults.standard.set(value != "off", forKey: Preferences.liveMix)
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
                    } else if arrived == songs.count, player.progress.currentTime > 45 {
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

    /// A song made to a click (kick, hi-hat, a chord per bar), `seconds` long with a second of
    /// silence at each end, quieter for its first `introBars` bars, saved as AAC (`alac`: in ALAC,
    /// 16 bit, as the "Massima" downloads are kept).
    nonisolated private static func writeDemoSong(to url: URL, bpm: Double, root: Int, introBars: Int, seconds: Double = 72,
                                                  alac: Bool = false) throws {
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let frames = Int(seconds * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let beat = 60 / bpm
        var noise: UInt32 = 7
        for frame in 0..<frames {
            let time = Double(frame) / rate - 1
            var value = 0.0
            if time >= 0, time < seconds - 2 {
                let beatIndex = Int(time / beat)
                let sinceBeat = time - Double(beatIndex) * beat
                let accent: Double = beatIndex % 4 == 0 ? 1.3 : 1
                let sweep: Double = 50 + 80 * exp(-sinceBeat * 40)
                value += 0.7 * sin(2 * Double.pi * sweep * sinceBeat) * exp(-sinceBeat * 16) * accent
                let sinceHat = sinceBeat - beat / 2
                if sinceHat >= 0 {
                    noise = noise &* 1_664_525 &+ 1_013_904_223
                    value += 0.12 * (Double(noise >> 8) / Double(1 << 24) * 2 - 1) * exp(-sinceHat * 60)
                }
                let bar = beatIndex / 4
                let chord = [root, root + 5, root + 7, root][bar % 4]
                let sinceBar = time - Double(bar) * 4 * beat
                for interval in [0, 4, 7] {
                    let pitch = 440 * pow(2, Double(chord + interval - 69) / 12)
                    value += 0.06 * sin(2 * Double.pi * pitch * sinceBar)
                }
                if bar < introBars { value *= 0.35 }
            }
            channels[0][frame] = Float(value * 0.8)
            channels[1][frame] = Float(value * 0.8)
        }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = alac
            ? [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }
}
