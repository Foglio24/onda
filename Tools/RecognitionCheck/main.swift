import Foundation

// Miniature invented metadata follows the response shape in ShazamIO's pinned recognition cassette:
// https://github.com/shazamio/ShazamIO/blob/3578d409e647843d94492bfdccb39dcdc7983222/tests/cassettes/test_recognize/test_recognize_bytes.yaml
// No recording or acoustic signature from that cassette is redistributed or sent to a service.
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
func rejects(_ expected: RecognitionAPI.Failure, _ message: String, _ operation: () throws -> Void) {
    do { try operation(); expect(false, message) }
    catch let error as RecognitionAPI.Failure { expect(error == expected, message) }
    catch { expect(false, "\(message): unexpected error type") }
}

let fixture = try Data(contentsOf: URL(fileURLWithPath: "Tools/RecognitionCheck/fixtures/match.json"))
guard let song = try RecognitionAPI.parse(data: fixture) else { fatalError("fixture must match") }
expect(song.title == "Test Song" && song.artist == "Test Artist", "reads title and subtitle")
expect(song.track.videoId == nil, "recognized track remains unresolved until YouTube lookup")
expect(song.album == "Test Album" && song.label == "Test Label" && song.releaseDate == "2026", "reads metadata only from SONG sections")
expect(song.genre == "Pop" && song.isrc == "USAAA2600001" && song.composer == nil, "keeps optional catalogue fields")
expect(song.track.artworkURL?.lastPathComponent == "large.jpg", "prefers high-quality cover")
expect(song.appleMusicURL?.host == "music.apple.com", "finds Apple Music page in nested hub options, ignoring audio previews")
expect(song.spotifyURL?.host == "open.spotify.com" && song.songURL?.host == "www.shazam.com", "reads safe service links")
let emptyMatch = try RecognitionAPI.parse(data: json(["matches": []]))
expect(emptyMatch == nil, "only an explicit empty matches array means no match")

let minimal: [String: Any] = ["matches": [["id": "a"]], "track": ["title": " Song ", "subtitle": " Artist "]]
let sparse = try RecognitionAPI.parse(data: json(minimal))
expect(sparse?.title == "Song" && sparse?.album == nil && sparse?.track.artworkURL == nil, "optional metadata is not required")
let invalidEnvelopes: [[String: Any]] = [[:], ["matches": NSNull()], ["matches": "wrong"], ["matches": [NSNull()]], ["matches": [[:]]], ["matches": [["id": "a"]]], ["matches": [["id": "a"]], "track": ["title": "Only title"]]]
for invalid in invalidEnvelopes {
    rejects(.invalidResponse, "rejects malformed match envelope") { _ = try RecognitionAPI.parse(data: json(invalid)) }
}
rejects(.invalidResponse, "rejects invalid JSON") { _ = try RecognitionAPI.parse(data: Data("not json".utf8)) }
rejects(.invalidResponse, "bounds response size") { _ = try RecognitionAPI.parse(data: Data(repeating: 32, count: RecognitionAPI.maximumResponseBytes + 1)) }
rejects(.invalidResponse, "bounds required metadata strings") {
    _ = try RecognitionAPI.parse(data: json(["matches": [["id": "a"]], "track": ["title": String(repeating: "x", count: 4097), "subtitle": "Artist"]]))
}

var unsafe = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
var unsafeTrack = unsafe["track"] as! [String: Any]
unsafeTrack["url"] = "javascript:alert(1)"
unsafeTrack["images"] = ["coverarthq": "https://name:secret@example.com/cover.jpg", "coverart": "http://example.com/cover.jpg"]
unsafeTrack["hub"] = ["actions": [["uri": "spotify:track:123"], ["uri": "https://music.apple.com.attacker.test/song"], ["uri": "https://name:secret@music.apple.com/song"], ["uri": "http://open.spotify.com/track/123"]]]
unsafe["track"] = unsafeTrack
let filtered = try RecognitionAPI.parse(data: json(unsafe))
expect(filtered?.appleMusicURL == nil && filtered?.spotifyURL == nil && filtered?.songURL == nil && filtered?.track.artworkURL == nil, "rejects insecure, credentialed and misleading service links")

for (status, failure) in [(401, RecognitionAPI.Failure.refused), (403, .refused), (429, .rateLimited), (500, .server), (503, .server), (302, .invalidResponse), (404, .invalidResponse)] {
    rejects(failure, "stops on HTTP \(status)") { _ = try RecognitionAPI.parse(data: fixture, statusCode: status) }
}

let signature = Data(repeating: 1, count: 64)
let request = try RecognitionAPI.request(signature: signature, sampleDuration: 12, date: Date(timeIntervalSince1970: 1000))
expect(request.url?.scheme == "https" && request.url?.host == "amp.shazam.com" && request.httpMethod == "POST", "uses fixed HTTPS discovery endpoint")
let components = request.url?.pathComponents ?? []
expect(components.count == 10 && Array(components.dropFirst().prefix(7)) == ["discovery", "v5", "en-US", "GB", "iphone", "-", "tag"], "uses fixed locale and route")
expect(components.suffix(2).allSatisfy { UUID(uuidString: $0) != nil }, "request IDs are UUIDs")
expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Seaglass/") == true, "identifies Seaglass honestly")
let headers = request.allHTTPHeaderFields ?? [:]
expect(!headers.keys.contains { $0.lowercased().hasPrefix("x-shazam") || ["authorization", "cookie"].contains($0.lowercased()) }, "sends no impersonation, authentication or cookie headers")
let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
let encoded = body["signature"] as? [String: Any]
expect(encoded?["samplems"] as? Int == 12000 && encoded?["uri"] as? String == "data:audio/vnd.shazam.sig;base64," + signature.base64EncodedString(), "encodes only the compact fingerprint with its duration")
expect((body["geolocation"] as? [String: String])?.isEmpty == true && (body["context"] as? [String: String])?.isEmpty == true, "does not invent or include a location fix")
expect((body["timestamp"] as? NSNumber)?.int64Value == 1_000_000, "timestamp is epoch milliseconds")
for duration in [0.0, -1.0, .infinity, .nan, 12.1] {
    rejects(.invalidSample, "bounds signature duration") { _ = try RecognitionAPI.request(signature: signature, sampleDuration: duration) }
}
rejects(.invalidSample, "rejects empty fingerprint") { _ = try RecognitionAPI.request(signature: Data(), sampleDuration: 12) }
rejects(.invalidSample, "bounds fingerprint bytes") { _ = try RecognitionAPI.request(signature: Data(repeating: 1, count: RecognitionAPI.maximumSignatureBytes + 1), sampleDuration: 12) }
print("RecognitionCheck: \(checks) checks passed")
