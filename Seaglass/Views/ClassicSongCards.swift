import CoreLocation
import SwiftUI

/// Under the classic player, after the lyrics and the next songs, as the common streaming apps
/// show them: the artist (photo, monthly listeners, biography), their concerts, nearest first
/// when the user lets the app know roughly where they are, and the song's credits. iPhone and
/// iPad only (NowPlayingView); nothing for an episode.
struct ClassicSongCards: View {
    let track: Track

    @StateObject private var model = ClassicSongCardsModel()
    @ObservedObject private var location = NearbyLocation.shared
    @EnvironmentObject private var router: AppRouter
    @State private var bioExpanded = false
    @State private var showEvents = false

    var body: some View {
        VStack(spacing: 18) {
            if let artist = model.artist { artistCard(artist) }
            if !selection.events.isEmpty { eventsCard }
            if !people.isEmpty { creditsCard }
        }
        .onAppear { model.show(track) }
        .onChange(of: track) { model.show(track) }
        .onChange(of: model.artistKey) { bioExpanded = false }
        .onAppear { if !model.events.isEmpty { location.refresh() } }
        .onChange(of: model.events) { if !model.events.isEmpty { location.refresh() } }
        .sheet(isPresented: $showEvents) {
            LiveEventsSheet(artist: artistName, events: model.events, selection: selection)
        }
    }

    // MARK: Artist

    private func artistCard(_ page: ArtistPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { openArtist() } label: {
                CachedImage(url: page.artworkURL, pixels: 1200) { Rectangle().fill(Color.primary.opacity(0.08)) }
                    .frame(maxWidth: .infinity)
                    .frame(height: 230)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        Text("Informazioni sull'artista")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 6)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                            }
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(page.name)
                            .font(.title3.weight(.bold))
                            .lineLimit(2)
                        if let listeners = page.monthlyListeners {
                            Text(listeners)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary.opacity(0.7))
                        }
                    }
                    Spacer(minLength: 8)
                    capsuleButton("Vai all'artista") { openArtist() }
                }
                if let about = page.about?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(about)
                            .font(.subheadline)
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .lineLimit(bioExpanded ? nil : 3)
                        // Three lines hold about 150 characters on an iPhone.
                        if about.count > 150 {
                            Button {
                                withAnimation(.smooth(duration: 0.3)) { bioExpanded.toggle() }
                            } label: {
                                Group {
                                    if bioExpanded { Text("mostra meno") } else { Text("mostra altro") }
                                }
                                .font(.subheadline.weight(.bold))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.1))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func openArtist() {
        router.page = .artist(id: track.artistID, name: track.primaryArtist)
    }

    // MARK: Concerts

    private var artistName: String { model.artist?.name ?? track.primaryArtist }

    private var selection: LiveEventSelection {
        LiveEventSelection.choose(from: model.events,
                                  latitude: location.coordinate?.latitude, longitude: location.coordinate?.longitude,
                                  region: Locale.current.region?.identifier)
    }

    private var eventsCard: some View {
        let shown = selection
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Eventi dal vivo")
                    .font(.headline.weight(.bold))
                Spacer(minLength: 8)
                if let scope = Self.scopeLabel(shown.scope) {
                    Label(scope, systemImage: "location.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .labelStyle(.titleAndIcon)
                }
            }
            CachedImage(url: model.artist?.artworkURL ?? track.largeArtworkURL, pixels: 1200) {
                Rectangle().fill(Color.primary.opacity(0.08))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(artistName)
                    .font(.subheadline.weight(.bold))
                if let first = shown.first, let last = shown.last {
                    Text(Self.range(first, last))
                        .font(.subheadline)
                }
                Text(shown.events.count == 1 ? String(localized: "1 evento") : String(localized: "\(shown.events.count) eventi"))
                    .font(.subheadline)
                    .foregroundStyle(Color.primary.opacity(0.7))
            }
            HStack(spacing: 10) {
                capsuleButton("Trova biglietti") { showEvents = true }
                if location.canAsk {
                    Button { location.request() } label: {
                        Label("Mostra gli eventi vicino a te", systemImage: "location")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.1), in: .rect(cornerRadius: 12))
    }

    static func scopeLabel(_ scope: LiveEventSelection.Scope) -> String? {
        switch scope {
        case .nearby: return String(localized: "Vicino a te")
        case .country(let code): return Locale.current.localizedString(forRegionCode: code)
        case .everywhere: return nil
        }
    }

    /// "12 dic 2026 – 23 apr 2027", or the one day.
    static func range(_ first: Date, _ last: Date) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)
        let start = first.formatted(style)
        let end = last.formatted(style)
        return start == end ? start : "\(start) – \(end)"
    }

    // MARK: Credits

    private var people: [SongDetails.Person] {
        guard model.creditsFor == track.id else { return [] }
        return (model.details ?? SongDetails()).people(artists: Self.artists(of: track))
    }

    /// The song's artists: the first as it is (a name can hold a comma), then the others.
    static func artists(of track: Track) -> [String] {
        let first = track.primaryArtist
        guard !first.isEmpty else { return [] }
        guard track.artist.hasPrefix(first) else { return [first] }
        let rest = track.artist.dropFirst(first.count).components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return [first] + rest
    }

    private var creditsCard: some View {
        let artists = Set(Self.artists(of: track).map { $0.lowercased() })
        let shown = Array(people.prefix(4))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Riconoscimenti")
                    .font(.headline.weight(.bold))
                Spacer(minLength: 8)
                if !track.isLocal, track.videoId != nil {
                    Button { router.page = .song(track) } label: {
                        Text("Mostra tutto")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.primary.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(shown, id: \.name) { person in
                let isArtist = artists.contains(person.name.lowercased())
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(person.roles.joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(Color.primary.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if isArtist {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.primary.opacity(0.6))
                    }
                }
                .contentShape(.rect)
                // Only the song's artists open a page: a songwriter's name could find someone else's.
                .onTapGesture {
                    guard isArtist else { return }
                    router.page = .artist(id: person.name == track.primaryArtist ? track.artistID : nil, name: person.name)
                }
                .accessibilityAddTraits(isArtist ? .isButton : [])
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.1), in: .rect(cornerRadius: 12))
    }

    // MARK: Pieces

    private func capsuleButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.55), lineWidth: 1) }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// What the cards show for the playing song, loaded as it changes: the artist's page and concerts
/// only when the artist changes (two songs in a row by them share one lookup), the credits for each
/// song. Only while the full player is open: it exists only then.
@MainActor
final class ClassicSongCardsModel: ObservableObject {
    @Published private(set) var artist: ArtistPage?
    @Published private(set) var events: [LiveEvent] = []
    @Published private(set) var details: SongDetails?
    /// The song whose credits `details` are (nil: still loading).
    @Published private(set) var creditsFor: String?
    /// The artist shown (their page's ID and name), nil before any.
    @Published private(set) var artistKey: String?

    private var artistTask: Task<Void, Never>?
    private var creditsTask: Task<Void, Never>?
    private var creditsKey: String?

    func show(_ track: Track) {
        guard !track.isPodcastEpisode else {
            artistTask?.cancel()
            creditsTask?.cancel()
            artistKey = nil
            creditsKey = nil
            artist = nil
            events = []
            creditsFor = nil
            details = nil
            return
        }
        let key = (track.artistID ?? "") + "|" + track.primaryArtist.lowercased()
        if key != artistKey {
            artistKey = key
            artist = nil
            events = []
            artistTask?.cancel()
            artistTask = Task { [weak self] in await self?.loadArtist(track, key: key) }
        }
        if track.id != creditsKey {
            creditsKey = track.id
            creditsFor = nil
            details = nil
            creditsTask?.cancel()
            creditsTask = Task { [weak self] in await self?.loadCredits(track) }
        }
    }

    private func loadArtist(_ track: Track, key: String) async {
        let name = track.primaryArtist
        guard !name.isEmpty else { return }
        let page = try? await InnerTube.shared.artist(id: track.artistID, name: name)
        guard artistKey == key, !Task.isCancelled else { return }
        guard let page else {
            // Not found or no network: the artist's next song tries again.
            artistKey = nil
            return
        }
        artist = page
        // Concerts come through the account service; a build without one shows none.
        guard let origin = AccountService.shared.origin else { return }
        let found = (try? await LiveEvents.load(artist: page.name.isEmpty ? name : page.name, from: origin,
                                                session: AccountService.session)) ?? []
        guard artistKey == key, !Task.isCancelled else { return }
        events = found
    }

    private func loadCredits(_ track: Track) async {
        guard let videoId = track.videoId, !track.isLocal else {
            // A song of the user's own: its artists only.
            creditsFor = track.id
            return
        }
        let loaded = try? await SongDetails.load(videoId: videoId)
        guard creditsKey == track.id, !Task.isCancelled else { return }
        details = loaded
        creditsFor = track.id
    }
}

/// "Trova biglietti": the artist's concerts, nearest or in the region first as in the card, with
/// all their dates a tap away; a concert opens its tickets' page.
struct LiveEventsSheet: View {
    let artist: String
    let events: [LiveEvent]
    let selection: LiveEventSelection

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var location = NearbyLocation.shared
    @State private var showAll = false

    private var shown: [LiveEvent] {
        guard showAll || selection.scope == .everywhere else { return selection.events }
        return LiveEventSelection.choose(from: events, latitude: nil, longitude: nil, region: nil).events
    }

    var body: some View {
        NavigationStack {
            List {
                if selection.scope != .everywhere {
                    Picker("Eventi dal vivo", selection: $showAll) {
                        Text(ClassicSongCards.scopeLabel(selection.scope) ?? "").tag(false)
                        Text("Tutte le date").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    ForEach(shown) { event in
                        Button { openURL(event.ticketsURL) } label: { row(event) }
                            .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Date e biglietti da Ticketmaster.")
                }
            }
            .navigationTitle(artist)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ event: LiveEvent) -> some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(event.day.formatted(Date.FormatStyle(timeZone: .gmt).month(.abbreviated)).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(event.day.formatted(Date.FormatStyle(timeZone: .gmt).day()))
                    .font(.title3.weight(.bold))
            }
            .frame(width: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(place(event))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(details(event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if event.postponed {
                Text("Rinviato")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.2), in: .capsule)
            }
            Image(systemName: "arrow.up.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }

    private func place(_ event: LiveEvent) -> String {
        var parts = [event.city].compactMap { $0 }
        if let code = event.country, code != Locale.current.region?.identifier,
           let country = Locale.current.localizedString(forRegionCode: code) {
            parts.append(country)
        }
        return parts.isEmpty ? (event.venue ?? event.name) : parts.joined(separator: ", ")
    }

    /// "San Siro · sabato 21:00 · 45 km"
    private func details(_ event: LiveEvent) -> String {
        var parts: [String] = []
        if let venue = event.venue { parts.append(venue) }
        var when = event.day.formatted(Date.FormatStyle(timeZone: .gmt).weekday(.wide))
        if let time = event.time { when += " \(time)" }
        parts.append(when)
        if let here = location.coordinate,
           let kilometres = event.distance(fromLatitude: here.latitude, longitude: here.longitude) {
            parts.append(Measurement(value: kilometres.rounded(), unit: UnitLength.kilometers)
                .formatted(.measurement(width: .abbreviated, usage: .road)))
        }
        return parts.joined(separator: " · ")
    }
}
