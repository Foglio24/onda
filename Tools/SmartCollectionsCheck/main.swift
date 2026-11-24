// Checks the library's smart collections (Seaglass/Services/SmartCollections.swift):
// - with an empty library every collection is empty, and the favourites' rule knows no log;
// - Ascoltati di recente is the history's first 50 songs (it keeps them most recent first, no dates);
// - a listen counts from 30 seconds (half of a song shorter than a minute), never a song left at once;
// - Preferiti che ascolti poco: favourites with at most one counted listen since the log began, the
//   least listened first, then in the favourites' order; a favourite never played (or without a video
//   ID) counts none; with no log, the favourites that aren't in the history;
// - Scaricati and the offline filter keep only the songs whose file is on the device.
// Run from the repository root: bash Tools/SmartCollectionsCheck/run.sh
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

func song(_ index: Int, id: Bool = true, length: TimeInterval = 200) -> Track {
    Track(videoId: id ? "video\(index)" : nil, title: "Song \(index)", artists: ["Artist \(index % 3)"], duration: length)
}
func event(_ track: Track, _ listened: TimeInterval, daysAgo: Double = 1) -> ListenEvent {
    ListenEvent(videoId: track.videoId ?? "", artist: track.primaryArtist, date: Date.now.addingTimeInterval(-daysAgo * 86_400),
                listened: listened, length: track.duration, skipped: false)
}
let videoId: (Track) -> String? = { $0.videoId }

// MARK: An empty library

expect(SmartCollections.recent(history: []).isEmpty, "with no history Ascoltati di recente is empty")
expect(SmartCollections.downloaded([], isOnDevice: { _ in true }).isEmpty, "with no downloads Scaricati is empty")
let empty = SmartCollections.forgottenFavourites(liked: [], events: [], history: [], videoId: videoId)
expect(empty.tracks.isEmpty && empty.since == nil, "with no favourites and no log Preferiti che ascolti poco is empty and has no start date")
expect(SmartCollections.availableOffline([], isOnDevice: { _ in true }).isEmpty, "nothing to play offline in nothing")

// MARK: Ascoltati di recente

let history = (1...120).map { song($0) }
let recent = SmartCollections.recent(history: history)
expect(recent.count == SmartCollections.recentLimit && recent.first == history.first && recent.last == history[SmartCollections.recentLimit - 1],
       "Ascoltati di recente is the history's first \(SmartCollections.recentLimit), most recent first")
expect(SmartCollections.recent(history: Array(history.prefix(7))).count == 7, "a short history is shown whole")

// MARK: A listen that counts

expect(SmartCollections.counts(event(song(1), 30)), "30 seconds count")
expect(!SmartCollections.counts(event(song(1), 29.9)), "29.9 seconds don't")
expect(SmartCollections.counts(event(song(2, length: 40), 20)), "half of a 40-second song counts")
expect(!SmartCollections.counts(event(song(3, length: 40), 3)), "3 seconds of a short song don't")
expect(!SmartCollections.counts(event(song(4, length: 0.5), 0.2)), "a song left at once never counts")

// MARK: Preferiti che ascolti poco

let liked = [song(10), song(11), song(12), song(13), song(14, id: false)]
let events = [event(liked[0], 200), event(liked[0], 180), event(liked[0], 60),  // three listens
              event(liked[1], 45),                                              // one
              event(liked[2], 5), event(liked[2], 12),                          // only seconds: none
              event(song(99), 300, daysAgo: 40)]                                // another song, the log's oldest
let forgotten = SmartCollections.forgottenFavourites(liked: liked, events: events, history: history, videoId: videoId)
let ids = forgotten.tracks.map(\.id)
print("listened to little: \(forgotten.tracks.map(\.title)), counts \(forgotten.listens)")
expect(!ids.contains(liked[0].id), "three listens aren't few")
expect(ids == [liked[2].id, liked[3].id, liked[4].id, liked[1].id],
       "none first (seconds only, never, no video ID) in the favourites' order, then the one listened to once")
expect(forgotten.listens[liked[1].videoId ?? ""] == 1 && forgotten.listens[liked[2].videoId ?? ""] == 0, "the counts shown are the counted listens")
if let since = forgotten.since {
    expect(abs(since.timeIntervalSinceNow + 40 * 86_400) < 5, "the rule counts from the log's oldest play (40 days ago)")
} else {
    expect(false, "the rule has a start date with a log")
}
// No log: the favourites that aren't in the history (a favourite known only by title and artist
// matches the same recording found on YouTube Music).
let found = Track(videoId: "video14found", title: "Song 14", artists: ["Artist 2"], duration: 200)
let noLog = SmartCollections.forgottenFavourites(liked: liked, events: [], history: [found, song(13)], videoId: videoId)
expect(noLog.since == nil, "with no log there is no start date")
expect(noLog.tracks.map(\.id) == [liked[0].id, liked[1].id, liked[2].id],
       "with no log, the favourites not in the history (\(noLog.tracks.map(\.title)))")

// MARK: Scaricati and offline

let downloads = [song(20), song(21), song(22)]
let onDevice: Set<String> = ["video20", "video22", "video10"]
let isOnDevice: (Track) -> Bool = { $0.videoId.map(onDevice.contains) ?? false }
expect(SmartCollections.downloaded(downloads, isOnDevice: isOnDevice).map(\.id) == [downloads[0].id, downloads[2].id],
       "Scaricati keeps the downloads whose file is on the device, in their order")
expect(SmartCollections.availableOffline(liked, isOnDevice: isOnDevice).map(\.id) == [liked[0].id],
       "offline, only the songs on the device")

print(failures == 0 ? "SmartCollectionsCheck: all passed" : "SmartCollectionsCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
