// Checks how the direct audio links are read from YouTube's player answer (see DirectStreams),
// on an answer in the shape the visionOS client returns, without the network.
// Run from the repository root: bash Tools/StreamCheck/run.sh
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

func format(_ itag: Int, _ mime: String, bitrate: Int, url: Bool = true, extra: [String: Any] = [:]) -> [String: Any] {
    var format: [String: Any] = ["itag": itag, "mimeType": mime, "bitrate": bitrate + 1_000, "averageBitrate": bitrate]
    if url { format["url"] = "https://rr1---sn-test.googlevideo.com/videoplayback?itag=\(itag)" }
    else { format["signatureCipher"] = "s=abc&url=https%3A%2F%2Fexample.com" }
    return format.merging(extra) { $1 }
}

let answer: [String: Any] = [
    "playabilityStatus": ["status": "OK"],
    "playerConfig": ["audioConfig": ["loudnessDb": 1.5]],
    "streamingData": [
        "expiresInSeconds": "21540",
        "adaptiveFormats": [
            format(137, "video/mp4; codecs=\"avc1.640028\"", bitrate: 4_000_000),
            format(139, "audio/mp4; codecs=\"mp4a.40.5\"", bitrate: 48_000),
            format(140, "audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 129_000),
            format(140, "audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 128_000, extra: ["isDrc": true]),
            format(250, "audio/webm; codecs=\"opus\"", bitrate: 70_000, url: false),
            format(251, "audio/webm; codecs=\"opus\"", bitrate: 133_000),
            format(251, "audio/webm; codecs=\"opus\"", bitrate: 131_000,
                   extra: ["audioTrack": ["displayName": "Deutsch", "audioIsDefault": false]]),
            format(328, "audio/mp4; codecs=\"ec-3\"", bitrate: 384_000),
        ],
    ],
]

let result = DirectStreams.parse(answer)
let found = result.renditions.map { "\($0.format)/\($0.bitrate)" }
expect(found == ["aac/48000", "aac/129000", "opus/133000", "dolby/384000"],
       "audio only, no DRC copy, no dubbed track, no ciphered link: \(found)")
expect(result.renditions.first { $0.format == .opus }?.isNative == false, "WebM Opus needs decoding")
expect(result.renditions.filter { $0.format != .opus }.allSatisfy(\.isNative), "MP4 renditions play natively")
expect(result.loudness == 1.5, "loudness comes with the same answer")
let lifetime = result.expires.timeIntervalSinceNow
expect(lifetime > 19_000 && lifetime < 20_000, "links kept for their lifetime minus a margin: \(Int(lifetime)) s")

let empty = DirectStreams.parse(["playabilityStatus": ["status": "LOGIN_REQUIRED"]])
expect(empty.renditions.isEmpty, "a refused answer has no renditions")

let label = ResolvedStream(url: URL(string: "https://example.com")!, format: .opus, bitrate: 160_400).label
expect(label == "Opus · 160 kbps", "label: \(label)")

print(failures == 0 ? "StreamCheck: all checks passed" : "StreamCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
