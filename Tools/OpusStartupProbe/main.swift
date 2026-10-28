// Measures, with the real network and the app's own code, how long each way of starting a song
// takes, from the "tap" (the start of the step) to:
//   - links: the visionOS player request (DirectStreams), done once per song;
//   - AAC: AVPlayer on the AAC stream, until it is ready and until it reports playing;
//   - Opus, progressive (OpusStream): first byte, head, first decoded audio, item ready, playing;
//   - Opus, prepared: the first range read and decoded beforehand, then from the tap;
//   - Opus, whole file (up to 1.15): download and conversion to Apple Lossless before it can play.
// "Playing" is AVPlayer's state, not sound from a speaker (on a build machine without a sound card
// AVPlayer may never get there: the times up to "ready" still count). It runs on a Mac, not an
// iPhone: the network and the decoder's speed differ there (Settings → Diagnostica measures that).
// Usage (from the repository root): bash Tools/OpusStartupProbe/run.sh [videoId ...]
import AVFoundation
import Foundation

func ms(_ seconds: TimeInterval?) -> String {
    guard let seconds, seconds.isFinite else { return "—" }
    return "\(Int((seconds * 1000).rounded())) ms"
}

func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

/// Until the item is ready and the player reports playing (each nil if it doesn't within the limit).
func startPlayer(_ item: AVPlayerItem, from start: TimeInterval, limit: TimeInterval = 8) async -> (ready: TimeInterval?, playing: TimeInterval?) {
    let player = AVPlayer(playerItem: item)
    player.playImmediately(atRate: 1)
    var ready: TimeInterval?
    var playing: TimeInterval?
    while uptime() - start < limit, playing == nil {
        if ready == nil, item.status == .readyToPlay { ready = uptime() - start }
        if item.status == .failed { break }
        if player.timeControlStatus == .playing, player.currentTime().seconds > 0 { playing = uptime() - start }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if ready == nil, item.status == .readyToPlay { ready = uptime() - start }
    player.pause()
    player.replaceCurrentItem(with: nil)
    return (ready, playing)
}

@main
struct OpusStartupProbe {
    static func main() async {
        let videos = CommandLine.arguments.dropFirst().isEmpty ? ["dQw4w9WgXcQ"] : Array(CommandLine.arguments.dropFirst())
        let folder = FileManager.default.temporaryDirectory.appending(path: "opus-probe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for video in videos {
            print("== \(video)")
            var start = uptime()
            guard let result = try? await DirectStreams.fetch(video) else {
                print("   links: not available")
                continue
            }
            print("   links (visionOS client): \(ms(uptime() - start))")
            let aac = result.renditions.filter { $0.format == .aac && $0.isNative }.max { $0.bitrate < $1.bitrate }
            let opus = result.renditions.filter { $0.format == .opus }.max { $0.bitrate < $1.bitrate }

            for round in 1...2 {
                if let aac {
                    start = uptime()
                    let (ready, playing) = await startPlayer(AVPlayerItem(url: aac.url), from: start)
                    print("   [\(round)] AAC \(aac.bitrate / 1000) kbps, link known: ready \(ms(ready)), playing \(ms(playing))")
                }
                guard let opus else { continue }
                start = uptime()
                let stream = OpusStream(source: .remote(opus.url), destination: nil, duration: nil)
                stream.start()
                let item = stream.makeItem()
                let (ready, playing) = await startPlayer(item, from: start)
                let timing = stream.timing
                func since(_ time: TimeInterval?) -> TimeInterval? { time.map { $0 - start } }
                print("   [\(round)] Opus \(opus.bitrate / 1000) kbps progressive, link known: first byte \(ms(since(timing.firstByte))),"
                      + " head \(ms(since(timing.head))), first audio \(ms(since(timing.firstAudio))),"
                      + " ready \(ms(ready)), playing \(ms(playing))")
                _ = try? await stream.completedFile()
                print("        whole song in after \(ms(since(stream.timing.completed)))")

                // A seek far ahead right after the start: AVPlayer waits until the audio there is decoded.
                let seeking = OpusStream(source: .remote(opus.url), destination: nil, duration: nil)
                seeking.start()
                let seekItem = seeking.makeItem()
                let seekPlayer = AVPlayer(playerItem: seekItem)
                seekPlayer.playImmediately(atRate: 1)
                try? await seeking.waitForAudio(seconds: 1)
                let duration = (try? await seekItem.asset.load(.duration))?.seconds ?? 0
                start = uptime()
                let target = duration * 0.75
                _ = await seekItem.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                let sought = uptime() - start
                var resumed: TimeInterval?
                while uptime() - start < 10, resumed == nil {
                    if seekPlayer.timeControlStatus == .playing, seekPlayer.currentTime().seconds > target { resumed = uptime() - start }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                print("   [\(round)] Opus progressive, seek to 75 % one second in: seek done \(ms(sought)), playing there \(ms(resumed))"
                      + " (\(String(format: "%.0f", seeking.decodedSeconds)) s decoded by then)")
                seekPlayer.pause()
                seeking.cancel()

                // Prepared: the first range read and decoded before the tap.
                let prepared = OpusStream(source: .remote(opus.url), destination: nil, duration: nil, firstRange: 128 << 10)
                let preparing = uptime()
                prepared.start(prepareOnly: true)
                try? await prepared.waitForAudio(seconds: 3)
                let preparedIn = uptime() - preparing
                // As PreparedPlayback does: the player made and prerolled before the tap.
                let preparedItem = prepared.makeItem()
                let player = AVPlayer(playerItem: preparedItem)
                player.automaticallyWaitsToMinimizeStalling = false
                var waited = 0
                while preparedItem.status == .unknown, waited < 200 {
                    try? await Task.sleep(for: .milliseconds(10))
                    waited += 1
                }
                if preparedItem.status == .readyToPlay { _ = await player.preroll(atRate: 1) }
                start = uptime()
                prepared.resume()
                player.playImmediately(atRate: 1)
                var preparedPlaying: TimeInterval?
                while uptime() - start < 4, preparedPlaying == nil {
                    if player.timeControlStatus == .playing, player.currentTime().seconds > 0 { preparedPlaying = uptime() - start }
                    try? await Task.sleep(for: .milliseconds(2))
                }
                print("   [\(round)] Opus prepared (\(ms(preparedIn)) beforehand, \(String(format: "%.1f", prepared.decodedSeconds)) s decoded):"
                      + " from the tap, playing \(ms(preparedPlaying)) (item \(preparedItem.status == .readyToPlay ? "ready" : "not ready"))")
                player.pause()
                prepared.cancel()
            }

            // The whole file first, as up to 1.15.
            if let opus {
                start = uptime()
                let webm = folder.appending(path: "\(video).webm")
                let lossless = folder.appending(path: "\(video).m4a")
                do {
                    try await ChunkedDownload.fetch(opus.url, to: webm)
                    let downloaded = uptime() - start
                    try OpusPipeline.transcode(webm: webm, to: lossless)
                    print("   Opus whole file: downloaded \(ms(downloaded)), converted to Apple Lossless \(ms(uptime() - start - downloaded)),"
                          + " playable after \(ms(uptime() - start))")
                } catch {
                    print("   Opus whole file: \(error)")
                }
            }
        }
    }
}
