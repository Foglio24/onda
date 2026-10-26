// Tests the identity/reconciliation helpers used by Library and the download queue.
// Run from the repository root: bash Tools/LibraryCheck/run.sh
import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let lastfm = Track(videoId: nil, title: "Example Song", artists: ["Example Artist"])
let studio = Track(videoId: "studio-video", title: "Example Song", artists: ["Example Artist"])
let live = Track(videoId: "live-video", title: "Example Song", artists: ["Example Artist"])
let unrelated = Track(videoId: "another-video", title: "Another Song", artists: ["Another Artist"])
let spelling = Track(videoId: nil, title: "  EXAMPLE   SÓNG ", artists: ["Éxample Artist"])
expect(lastfm.isSameRecording(as: studio), "Last.fm matches a resolved version")
expect(studio.isSameRecording(as: lastfm), "Matching is symmetric")
expect(!studio.isSameRecording(as: live), "Different video IDs remain distinct")
expect(lastfm.isSameRecording(as: spelling), "Metadata normalizes case, accents and whitespace")
expect(!lastfm.isSameRecording(as: unrelated), "Unrelated metadata does not match")

let missingArtist = Track(videoId: nil, title: "Example Song", artists: [])
let resolvedMissingArtist = Track(videoId: "unknown-artist", title: "Example Song", artists: [])
expect(!missingArtist.isSameRecording(as: resolvedMissingArtist), "Missing artists do not merge recordings")

let oldDuplicates = [lastfm, unrelated, studio, live, lastfm].uniqued()
expect(oldDuplicates.map(\.id) == [studio.id, unrelated.id, live.id], "Legacy duplicates normalize without merging videos")
expect(oldDuplicates[0].sourceIDs?.contains(lastfm.id) == true, "Deduplication retains the Last.fm identity")

let reconciled = [lastfm, unrelated, studio, live].reconciling(original: lastfm, resolved: studio)
expect(reconciled.map(\.id) == [studio.id, unrelated.id, live.id], "Reconciliation preserves order and alternate videos")
expect(reconciled[0].isSameRecording(as: lastfm), "A favourite remains recognizable after resolution")
expect(reconciled.reconciling(original: lastfm, resolved: studio) == reconciled, "Reconciliation is idempotent")
expect([unrelated].reconciling(original: lastfm, resolved: studio) == [unrelated], "Resolving never inserts unsaved songs")
expect([lastfm].reconciling(original: lastfm, resolved: studio).first?.videoId == studio.videoId,
       "An unresolved playlist row becomes downloadable")

let differentMetadata = Track(videoId: "studio-video", title: "Example Song (Official Audio)", artists: ["Artist Channel"])
let canonical = differentMetadata.retainingIdentity(of: lastfm)
expect(canonical.isSameRecording(as: lastfm), "Resolution retains identity when YouTube metadata differs")
expect(!canonical.isSameRecording(as: live), "An alias never merges different resolved videos")

let encoded = try JSONEncoder().encode(canonical)
let restored = try JSONDecoder().decode(Track.self, from: encoded)
expect(restored.isSameRecording(as: lastfm), "Aliases survive JSON persistence")
let legacyJSON = """
{"id":"example artist|example song","title":"Example Song","artist":"Example Artist","primaryArtist":"Example Artist"}
"""
let legacy = try JSONDecoder().decode(Track.self, from: Data(legacyJSON.utf8))
expect(legacy.sourceIDs == nil && legacy.isSameRecording(as: studio), "Old JSON without aliases still decodes and matches")

var toggled = reconciled
toggled.removeAll { $0.isSameRecording(as: studio) }
expect(toggled.map(\.id) == [unrelated.id, live.id], "Unliking the selected recording preserves another video")
print("LibraryCheck: \(checks) checks passed")
