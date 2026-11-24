// Checks the monthly recap (Seaglass/Services/MonthlyRecap.swift):
// - plays recorded before this version (no title) still decode, and new ones keep their title;
// - a song taken up again where it was left is one listen; a song played whole twice is two; a pause
//   of more than 12 hours, or another song between, keeps plays apart;
// - the month counts only its own plays: listens (from 30 seconds), minutes (all the time listened),
//   artists (one whatever their case), the top artists and songs (titles from the library for older
//   plays, none invented);
// - discoveries only when the log reaches back before the month; the period covered starts with the
//   log when it starts within the month; a month with few listens says so; an empty one is empty.
// Run from the repository root: bash Tools/MonthlyRecapCheck/run.sh
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Europe/Rome") ?? .current
func day(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
}
func play(_ id: String, _ artist: String, _ date: Date, _ listened: TimeInterval, length: TimeInterval = 200,
          title: String? = nil) -> ListenEvent {
    ListenEvent(videoId: id, artist: artist, date: date, listened: listened, length: length, skipped: false, title: title)
}

// MARK: Stored plays

let old = #"[{"videoId":"a","artist":"Old","date":800000000,"listened":120,"length":200,"skipped":false}]"#
if let decoded = try? JSONDecoder().decode([ListenEvent].self, from: Data(old.utf8)) {
    expect(decoded.count == 1 && decoded[0].title == nil, "a play recorded before this version still decodes, without a title")
} else {
    expect(false, "a play recorded before this version still decodes")
}
let withTitle = play("b", "New", day(11, 2), 100, title: "Song B")
if let data = try? JSONEncoder().encode([withTitle]), let back = try? JSONDecoder().decode([ListenEvent].self, from: data) {
    expect(back == [withTitle], "a new play keeps its title")
}

// MARK: One listen or two

let resumed = ListenHistory.merged([play("s", "A", day(11, 3, 20), 90), play("s", "A", day(11, 4, 7), 80)])
expect(resumed.count == 1 && resumed[0].listened == 170, "taken up again the next morning where it was left: one listen of 170 s")
let twice = ListenHistory.merged([play("s", "A", day(11, 3, 20), 200), play("s", "A", day(11, 3, 20, 4), 195)])
expect(twice.count == 2, "played whole twice: two listens")
let later = ListenHistory.merged([play("s", "A", day(11, 3, 8), 60), play("s", "A", day(11, 3, 21), 60)])
expect(later.count == 2, "more than 12 hours apart: two plays")
let between = ListenHistory.merged([play("s", "A", day(11, 3, 8), 60), play("t", "B", day(11, 3, 8, 5), 60),
                                    play("s", "A", day(11, 3, 8, 10), 60)])
expect(between.count == 3, "another song between: three plays")
expect(ListenHistory.counts(play("x", "A", day(11, 1), 30)) && !ListenHistory.counts(play("x", "A", day(11, 1), 29)),
       "a listen counts from 30 seconds")

// MARK: A month

var events: [ListenEvent] = []
// October: Alpha and Beta.
events += [play("a1", "Alpha", day(10, 20), 180, title: "Alpha One"), play("b1", "Beta", day(10, 25), 180)]
// November: Alpha ×5, beta ×3 (another case), Gamma ×2 (new), Delta ×1 (new, its title only in the library),
// a play left at once, and a song taken up again (one listen).
for d in 1...5 { events.append(play("a1", "Alpha", day(11, d), 200, title: "Alpha One")) }
for d in 6...8 { events.append(play("b1", "beta ", day(11, d), 150)) }
events += [play("g1", "Gamma", day(11, 9), 120, title: "Gamma Ray"), play("g1", "Gamma", day(11, 10), 120, title: "Gamma Ray"),
           play("d1", "Delta", day(11, 11), 100),
           play("e1", "Epsilon", day(11, 12), 5, title: "Gone"),
           play("g2", "Gamma", day(11, 13, 22), 60, title: "Gamma Two"), play("g2", "Gamma", day(11, 14, 9), 70, title: "Gamma Two")]
// December: one play, not November's.
events.append(play("a1", "Alpha", day(12, 1, 10), 200, title: "Alpha One"))
let november = MonthlyRecap.make(events: events.shuffled(), month: day(11, 15), calendar: calendar) { $0 == "d1" ? "Delta Song" : nil }
print("November: \(november.listens) listens, \(november.minutes) min, artists \(november.topArtists.map { "\($0.name) \($0.listens)" }), "
      + "songs \(november.topSongs.map { "\($0.title) \($0.listens)" }), discoveries \(november.discoveries ?? ["?"])")
expect(november.listens == 12, "November's listens: 5 + 3 + 2 + 1 + the one taken up again; the play left at once doesn't count (\(november.listens))")
let seconds = 5 * 200 + 3 * 150 + 2 * 120 + 100 + 5 + 60 + 70
expect(november.minutes == Int((Double(seconds) / 60).rounded()), "its minutes are all the time listened in it (\(november.minutes))")
expect(november.artistCount == 4, "four artists counted, Beta once whatever its case (\(november.artistCount))")
expect(november.topArtists.map(\.name) == ["Alpha", "beta", "Gamma", "Delta"],
       "the most listened artists first, equals by time listened (\(november.topArtists.map(\.name)))")
expect(november.topArtists.first?.listens == 5, "Alpha five times")
expect(november.topSongs.first?.title == "Alpha One" && november.topSongs.contains { $0.title == "Gamma Ray" },
       "the top songs with their titles")
expect(!november.topSongs.contains { $0.videoId == "b1" }, "a song with no title anywhere isn't shown (none invented)")
expect(MonthlyRecap.make(events: events, month: day(11, 15), calendar: calendar) { $0 == "d1" ? "Delta Song" : nil }
        .topSongs.count == 3, "three top songs at most")
expect(november.discoveries == ["Gamma", "Delta"], "discoveries: the artists never heard before November (\(november.discoveries ?? []))")
expect(november.coveredFrom == day(11, 1, 0), "a month the log covers whole starts on its first day")
expect(!november.hasFewListens, "twelve listens aren't few")

// The log's first month: it starts in the middle, and first times can't be told.
let october = MonthlyRecap.make(events: events, month: day(10, 1), calendar: calendar)
expect(october.coveredFrom == day(10, 20), "the period covered starts with the log's first play (20 October)")
expect(october.discoveries == nil, "no discoveries where the log doesn't reach back before the month")
expect(october.hasFewListens && october.listens == 2, "two listens are few: the recap says so")

// An empty month, and the months there are.
let september = MonthlyRecap.make(events: events, month: day(9, 10), calendar: calendar)
expect(september.listens == 0 && september.minutes == 0 && september.topArtists.isEmpty && september.coveredFrom == nil,
       "a month before the log is empty and covers nothing")
let none = MonthlyRecap.make(events: [], month: day(11, 10), calendar: calendar)
expect(none.listens == 0 && none.logStart == nil && none.discoveries == nil, "with no log the recap is empty")
let months = MonthlyRecap.months(events: events, now: day(12, 5), calendar: calendar)
expect(months == [day(12, 1, 0), day(11, 1, 0), day(10, 1, 0)], "the months with plays, the most recent first")
expect(MonthlyRecap.months(events: [], now: day(12, 5), calendar: calendar) == [day(12, 1, 0)], "with no plays, this month only")

print(failures == 0 ? "MonthlyRecapCheck: all passed" : "MonthlyRecapCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
