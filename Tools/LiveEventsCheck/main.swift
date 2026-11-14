// Checks the classic player's concerts: how the account service's answer is read (what can't be
// read is skipped, never a crash) and which concerts the card shows (near the device's position,
// else in its region, else all), without the network.
// Run from the repository root: bash Tools/LiveEventsCheck/run.sh
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

let answer = """
{"enabled": true, "events": [
  {"id": "mi", "name": "Live", "date": "2027-06-12", "time": "21:00", "venue": "San Siro", "city": "Milano", "country": "IT",
   "latitude": 45.478, "longitude": 9.124, "url": "https://www.ticketmaster.it/event/mi", "postponed": false},
  {"id": "ro", "date": "2027-06-15", "city": "Roma", "country": "it", "latitude": 41.934, "longitude": 12.455,
   "url": "https://www.ticketmaster.it/event/ro"},
  {"id": "be", "date": "2027-07-01", "city": "Berlin", "country": "DE", "latitude": null, "longitude": null,
   "url": "https://www.ticketmaster.de/event/be", "postponed": true},
  {"id": "ld", "date": "2027-05-01", "city": "London", "country": "GB", "latitude": 51.556, "longitude": -0.279,
   "url": "https://www.ticketmaster.co.uk/event/ld"},
  {"id": "old", "date": "2020-01-01", "city": "Paris", "country": "FR", "url": "https://www.ticketmaster.fr/event/old"},
  {"id": "http", "date": "2027-06-20", "url": "http://example.com/tickets"},
  {"id": "noday", "date": "soon", "url": "https://example.com/tickets"},
  {"id": "badday", "date": "2027-13-40", "url": "https://example.com/tickets"},
  {"id": "far", "date": "2027-08-01", "latitude": 500, "longitude": 9, "url": "https://example.com/far"},
  {"id": "mi", "date": "2027-06-12", "url": "https://www.ticketmaster.it/event/mi-again"},
  "not a concert", 42, null
]}
"""
let events = LiveEvents.parse(Data(answer.utf8))
expect(events.map(\.id) == ["mi", "ro", "be", "ld", "old", "far"], "readable concerts kept, once each: \(events.map(\.id))")
let milan = events.first { $0.id == "mi" }
expect(milan?.time == "21:00" && milan?.venue == "San Siro" && milan?.city == "Milano" && milan?.postponed == false,
       "a concert's details")
expect(events.first { $0.id == "ro" }?.country == "IT", "region codes in capitals")
expect(events.first { $0.id == "be" }.map { $0.latitude == nil && $0.postponed } == true, "a postponed concert without a position")
expect(events.first { $0.id == "far" }.map { $0.latitude == nil && $0.longitude == nil } == true, "an impossible position is dropped")

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
let day = milan.map { calendar.dateComponents([.year, .month, .day], from: $0.day) }
expect(day?.year == 2027 && day?.month == 6 && day?.day == 12, "the day is the calendar day in UTC")

expect(LiveEvents.parse(Data("[]".utf8)).isEmpty && LiveEvents.parse(Data("not json".utf8)).isEmpty
       && LiveEvents.parse(Data(#"{"events": {"id": 1}}"#.utf8)).isEmpty, "other answers give no concerts")

// Milan to Rome is about 480 km; Bergamo is about 45 km from San Siro.
let rome = events.first { $0.id == "ro" }
let distance = milan.flatMap { m in rome?.distance(fromLatitude: m.latitude ?? 0, longitude: m.longitude ?? 0) } ?? 0
expect(abs(distance - 480) < 15, "distance Milan–Rome: \(Int(distance)) km")

let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14))!
let bergamo = LiveEventSelection.choose(from: events, latitude: 45.698, longitude: 9.677, region: "IT", now: now)
expect(bergamo.scope == .nearby && bergamo.events.map(\.id) == ["mi"], "near Bergamo: Milan only (\(bergamo.events.map(\.id)))")
let naples = LiveEventSelection.choose(from: events, latitude: 40.852, longitude: 14.268, region: "IT", now: now)
expect(naples.scope == .nearby && naples.events.map(\.id) == ["ro"], "near Naples: Rome (\(naples.events.map(\.id)))")
let palermo = LiveEventSelection.choose(from: events, latitude: 38.116, longitude: 13.361, region: "IT", now: now)
expect(palermo.scope == .country("IT") && palermo.events.map(\.id) == ["mi", "ro"],
       "none near Palermo: the region's, by day (\(palermo.events.map(\.id)))")
let unknown = LiveEventSelection.choose(from: events, latitude: nil, longitude: nil, region: "it", now: now)
expect(unknown.scope == .country("IT"), "no position: the region's")
let japan = LiveEventSelection.choose(from: events, latitude: nil, longitude: nil, region: "JP", now: now)
expect(japan.scope == .everywhere && japan.events.map(\.id) == ["ld", "mi", "ro", "be", "far"],
       "none in the region: all upcoming ones, by day, not past ones (\(japan.events.map(\.id)))")
expect(japan.first == events.first { $0.id == "ld" }?.day && japan.last == events.first { $0.id == "far" }?.day,
       "the range runs from the first concert to the last")
let later = calendar.date(from: DateComponents(year: 2027, month: 6, day: 13))!
expect(LiveEventSelection.choose(from: events, latitude: nil, longitude: nil, region: "IT", now: later).events.map(\.id) == ["mi", "ro"],
       "a concert stays listed through its day")
expect(LiveEventSelection.choose(from: [], latitude: 45, longitude: 9, region: "IT", now: now).events.isEmpty, "no concerts, nothing to show")

print(failures == 0 ? "LiveEventsCheck: all checks passed" : "LiveEventsCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
