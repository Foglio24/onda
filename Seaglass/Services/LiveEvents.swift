import Foundation

/// An artist's upcoming concert, for "Eventi dal vivo" under the classic player. The account
/// service passes them on from Ticketmaster (server/account/src/events.mjs); only the artist's
/// name is sent. Which ones are near is worked out here, on the device.
struct LiveEvent: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// The concert's day where it happens, at midnight UTC: shown in UTC so no time zone moves it.
    let day: Date
    /// "21:00", the venue's own time.
    let time: String?
    let venue: String?
    let city: String?
    /// The region's code ("IT").
    let country: String?
    let latitude: Double?
    let longitude: Double?
    let ticketsURL: URL
    let postponed: Bool

    /// One concert of the service's answer; nil when it has no day or no HTTPS link to its tickets.
    init?(json: Any) {
        guard let item = J.dict(json),
              let date = J.string(item["date"]).flatMap(LiveEvent.day(from:)),
              let link = J.string(item["url"]).flatMap(URL.init(string:)), link.scheme == "https", link.host() != nil
        else { return nil }
        id = J.string(item["id"]).map { String($0.prefix(64)) } ?? link.absoluteString
        name = J.string(item["name"]) ?? ""
        day = date
        time = J.string(item["time"]).flatMap { $0.count == 5 ? $0 : nil }
        venue = J.string(item["venue"]).flatMap { $0.isEmpty ? nil : $0 }
        city = J.string(item["city"]).flatMap { $0.isEmpty ? nil : $0 }
        country = J.string(item["country"]).flatMap { $0.count == 2 ? $0.uppercased() : nil }
        let latitude = item["latitude"] as? Double
        let longitude = item["longitude"] as? Double
        if let latitude, let longitude, abs(latitude) <= 90, abs(longitude) <= 180 {
            self.latitude = latitude
            self.longitude = longitude
        } else {
            self.latitude = nil
            self.longitude = nil
        }
        ticketsURL = link
        postponed = item["postponed"] as? Bool ?? false
    }

    init(id: String, day: Date, city: String?, country: String?, latitude: Double?, longitude: Double?,
         ticketsURL: URL, name: String = "", time: String? = nil, venue: String? = nil, postponed: Bool = false) {
        self.id = id
        self.name = name
        self.day = day
        self.time = time
        self.venue = venue
        self.city = city
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
        self.ticketsURL = ticketsURL
        self.postponed = postponed
    }

    /// "2027-06-12", read as a calendar day.
    static func day(from text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard text.count == 10, parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Kilometres from a place to the venue, over the Earth's surface; nil without the venue's position.
    func distance(fromLatitude fromLat: Double, longitude fromLon: Double) -> Double? {
        guard let latitude, let longitude else { return nil }
        let radians = Double.pi / 180
        let dLat = (latitude - fromLat) * radians
        let dLon = (longitude - fromLon) * radians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(fromLat * radians) * cos(latitude * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6371 * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

/// The concerts the card shows, and how they were chosen.
struct LiveEventSelection: Equatable {
    enum Scope: Equatable {
        /// Within `radius` of the device's approximate position.
        case nearby
        /// In the device's region (its settings), when its position isn't known or none is near.
        case country(String)
        /// None near or in the region: all of them.
        case everywhere
    }

    /// Spotify's "near you" is about a city and the region around it.
    static let radius: Double = 300

    let scope: Scope
    let events: [LiveEvent]

    /// The concerts near the position when it's known and there are some, else those in the region;
    /// when there are none there either, all of them (still upcoming, by day). Past ones are dropped.
    static func choose(from events: [LiveEvent], latitude: Double?, longitude: Double?, region: String?,
                       now: Date = Date()) -> LiveEventSelection {
        let today = now.addingTimeInterval(-36 * 3600)
        let upcoming = events.filter { $0.day >= today }.sorted { $0.day < $1.day }
        if let latitude, let longitude {
            let near = upcoming.filter { ($0.distance(fromLatitude: latitude, longitude: longitude) ?? .infinity) <= radius }
            if !near.isEmpty { return LiveEventSelection(scope: .nearby, events: near) }
        }
        if let region = region?.uppercased(), region.count == 2 {
            let local = upcoming.filter { $0.country == region }
            if !local.isEmpty { return LiveEventSelection(scope: .country(region), events: local) }
        }
        return LiveEventSelection(scope: .everywhere, events: upcoming)
    }

    var first: Date? { events.first?.day }
    var last: Date? { events.last?.day }
}

enum LiveEvents {
    enum Failure: Error {
        case unavailable
    }

    /// The service's answer: at most 100 concerts, the ones that can't be read skipped.
    static func parse(_ data: Data) -> [LiveEvent] {
        guard data.count <= 1_000_000, let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var seen = Set<String>()
        return J.array(J.value(json, "events")).prefix(100).compactMap(LiveEvent.init(json:))
            .filter { seen.insert($0.id).inserted }
    }

    private actor Cache {
        var entries: [String: (time: Date, events: [LiveEvent])] = [:]

        func get(_ key: String) -> [LiveEvent]? {
            guard let entry = entries[key], Date().timeIntervalSince(entry.time) < 3600 else { return nil }
            return entry.events
        }

        func set(_ key: String, _ events: [LiveEvent]) {
            if entries.count > 50 { entries.removeAll() }
            entries[key] = (Date(), events)
        }
    }

    private static let cache = Cache()

    /// The artist's upcoming concerts from the account service at `origin` (kept for an hour, so
    /// the next song by the same artist asks nothing).
    static func load(artist: String, from origin: URL, session: URLSession) async throws -> [LiveEvent] {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { return [] }
        let key = name.lowercased()
        if let cached = await cache.get(key) { return cached }
        var components = URLComponents(url: origin.appending(path: "v1/events"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "artist", value: name)]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unavailable }
        let events = parse(data)
        await cache.set(key, events)
        return events
    }
}
