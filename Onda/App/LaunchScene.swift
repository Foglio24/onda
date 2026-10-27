import AVFoundation
import SwiftUI

/// Opens a given screen at launch, for the screenshots CI takes on a simulator
/// (Tools/Screenshots/run.sh): `-OndaScene home | library | settings | search:<query> |
/// artist:<browseId> | album:<browseId> | player:<videoId> | downloads:<videoId> | storage |
/// equalizer | info:<album browseId> | mix | mix:options | mix:edit`.
/// `mix` makes two short songs and a playlist of them, and opens their transition in the Mix editor
/// (`mix:options` with the options sheet too, `mix:edit` drawing the volume lines by hand).
/// `downloads` downloads the first songs of a song's radio and shows them downloading;
/// `storage` shows the space they take; `info` plays an album and opens its first song's details.
/// Launch arguments are never passed in normal use, so this does nothing then.
@MainActor
enum LaunchScene {
    private static var scene: String? { UserDefaults.standard.string(forKey: "OndaScene") }

    /// Library → Download is opened at launch.
    static var opensDownloads: Bool {
        scene?.hasPrefix("downloads") == true || opensStorage
    }

    /// Library → Download → Spazio occupato is opened at launch.
    static var opensStorage: Bool { scene == "storage" }

    /// Settings → Equalizzatore is opened at launch.
    static var opensEqualizer: Bool { scene == "equalizer" }

    /// `-OndaCardProgress 0.55`: the player card stops part of the way, to see it over the app.
    static var playerCardProgress: CGFloat? {
        guard scene != nil, let value = UserDefaults.standard.object(forKey: "OndaCardProgress") as? Double
                ?? UserDefaults.standard.string(forKey: "OndaCardProgress").flatMap({ Double($0) }) else { return nil }
        return CGFloat(max(0, min(1, value)))
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
                let first = Track(videoId: "OndaMixDemoA", title: "Neon Drive", artists: ["Onda Demo"], duration: 72)
                let second = Track(videoId: "OndaMixDemoB", title: "Night Run", artists: ["Onda Demo"], duration: 72)
                await Task.detached(priority: .userInitiated) {
                    try? Self.writeDemoSong(to: Storage.audioFile(for: "OndaMixDemoA"), bpm: 124, root: 57, introBars: 0)
                    try? Self.writeDemoSong(to: Storage.audioFile(for: "OndaMixDemoB"), bpm: 128, root: 60, introBars: 8)
                }.value
                let playlist = Library.shared.createPlaylist(named: "Mix demo", tracks: [first, second])
                router.mixTarget = MixTarget(playlistID: playlist.id, opensFirst: true,
                                             options: value == "options" ? .eq : nil,
                                             editing: value == "edit" ? .volume : nil)
            }
        case "player":
            Task {
                guard let tracks = try? await InnerTube.shared.radio(for: value), !tracks.isEmpty else { return }
                PlayerController.shared.play(tracks, source: "Radio")
                router.openPlayer()
            }
        default:
            select(.home)
        }
    }

    /// A short song made to a click (kick, hi-hat, a chord per bar), quieter for its first
    /// `introBars` bars, saved as AAC.
    nonisolated private static func writeDemoSong(to url: URL, bpm: Double, root: Int, introBars: Int) throws {
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let frames = Int(72 * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let beat = 60 / bpm
        var noise: UInt32 = 7
        for frame in 0..<frames {
            let time = Double(frame) / rate - 1
            var value = 0.0
            if time >= 0, time < 70 {
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
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        try file.write(from: buffer)
    }
}
