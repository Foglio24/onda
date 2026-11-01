import SwiftUI

// MARK: Podcasts

/// The library's podcasts: the episodes left halfway, the shows you follow, YouTube Music's
/// suggestions by topic, and a search for shows and episodes.
struct PodcastsView: View {
    @ObservedObject private var podcasts = PodcastLibrary.shared
    @State private var shelves: [PodcastShelf] = []
    @State private var topic: String?
    @State private var topicShows: [PodcastShow] = []
    @State private var query = ""
    @State private var foundShows: [PodcastShow] = []
    @State private var foundEpisodes: [PodcastEpisode] = []
    @State private var isSearching = false

    /// Topics to browse by, searched as written (in the iPhone's language).
    private static let topics: [String] = [
        String(localized: "Attualità"), String(localized: "Storia"), String(localized: "Scienza"),
        String(localized: "Comicità"), String(localized: "True crime"), String(localized: "Tecnologia"),
        String(localized: "Sport"), String(localized: "Economia"), String(localized: "Cultura"),
        String(localized: "Salute"),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    libraryContent
                } else {
                    searchContent
                }
            }
            .padding(.vertical, 8)
        }
        .background { AmbientBackground() }
        .navigationTitle("Podcast")
        .searchable(text: $query, prompt: Text("Podcast e puntate"))
        .task {
            guard shelves.isEmpty else { return }
            var found = (try? await InnerTube.shared.podcastShelves()) ?? []
            // The Home's suggestions don't always come (they depend on the place and the visitor):
            // then YouTube Music's podcasts for "podcast".
            if found.isEmpty, let shows = try? await InnerTube.shared.searchPodcasts(String(localized: "podcast")),
               !shows.isEmpty {
                found = [PodcastShelf(title: String(localized: "In evidenza"), shows: shows)]
            }
            shelves = found
        }
        .task(id: query) { await search() }
        .task(id: topic) {
            guard let topic else { return }
            topicShows = []
            topicShows = (try? await InnerTube.shared.searchPodcasts(topic)) ?? []
        }
    }

    // MARK: Library and suggestions

    @ViewBuilder private var libraryContent: some View {
        let inProgress = podcasts.inProgress
        if !inProgress.isEmpty {
            section(Text("Continua ad ascoltare")) {
                VStack(spacing: 16) {
                    ForEach(inProgress.prefix(10)) { episode in
                        EpisodeRow(episode: episode, showsShow: true)
                    }
                }
                .padding(.horizontal)
            }
        }
        if !podcasts.followed.isEmpty {
            section(Text("Seguiti")) { showShelf(podcasts.followed) }
        }
        ForEach(shelves) { shelf in
            section(Text(verbatim: shelf.title)) { showShelf(shelf.shows) }
        }
        section(Text("Per argomento")) {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Self.topics, id: \.self) { name in
                            Button {
                                topic = topic == name ? nil : name
                            } label: {
                                Text(name)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.glass)
                            .tint(topic == name ? .accentColor : nil)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
                if topic != nil {
                    if topicShows.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        showShelf(topicShows)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            title
                .font(.title3.bold())
                .padding(.horizontal)
            content()
        }
    }

    private func showShelf(_ shows: [PodcastShow]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(shows) { show in
                    NavigationLink { PodcastShowView(id: show.id) } label: { PodcastCard(show: show) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Search

    @ViewBuilder private var searchContent: some View {
        if !foundShows.isEmpty {
            section(Text("Podcast")) { showShelf(foundShows) }
        }
        if !foundEpisodes.isEmpty {
            section(Text("Puntate")) {
                VStack(spacing: 16) {
                    ForEach(foundEpisodes) { episode in
                        EpisodeRow(episode: episode, showsShow: true)
                    }
                }
                .padding(.horizontal)
            }
        }
        if foundShows.isEmpty && foundEpisodes.isEmpty {
            if isSearching {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                ContentUnavailableView.search(text: query).padding(.top, 40)
            }
        }
    }

    /// Shows and episodes together, a moment after typing stops.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            foundShows = []
            foundEpisodes = []
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        async let shows = InnerTube.shared.searchPodcasts(text)
        async let episodes = InnerTube.shared.searchEpisodes(text)
        let found = ((try? await shows) ?? [], (try? await episodes) ?? [])
        guard !Task.isCancelled else { return }
        foundShows = found.0
        foundEpisodes = found.1
        isSearching = false
    }
}

/// A podcast's square cover with its title and author, for horizontal rows.
struct PodcastCard: View {
    let show: PodcastShow
    var size: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedImage(url: show.artworkURL, pixels: Int(size * 3)) {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "mic.fill").font(.title).foregroundStyle(.secondary) }
            }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: 14))
            Text(show.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if !show.author.isEmpty {
                Text(show.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size, alignment: .leading)
        .contentShape(.rect)
    }
}

// MARK: A podcast's page

struct PodcastShowView: View {
    let id: String

    @ObservedObject private var podcasts = PodcastLibrary.shared
    @State private var page: PodcastShowPage?
    @State private var failure: String?
    @State private var loadingMore = false
    @State private var showsAllAbout = false

    var body: some View {
        ScrollView {
            if let page {
                content(page)
            } else if let failure {
                ContentUnavailableView("Podcast non disponibile", systemImage: "wifi.exclamationmark",
                                       description: Text(failure))
                    .padding(.top, 80)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 140)
            }
        }
        .background { AmbientBackground() }
        .navigationTitle(page?.show.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard page == nil else { return }
            do {
                page = try await InnerTube.shared.podcast(id)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func content(_ page: PodcastShowPage) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            header(page)
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(page.episodes) { episode in
                    EpisodeRow(episode: episode, linksShow: false)
                        .onAppear {
                            if episode.videoId == page.episodes.last?.videoId { Task { await loadMore() } }
                        }
                    Divider()
                }
                if loadingMore {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .padding()
    }

    private func header(_ page: PodcastShowPage) -> some View {
        VStack(spacing: 10) {
            CachedImage(url: page.show.artworkURL, pixels: 690) { Rectangle().fill(.quaternary) }
                .frame(width: 230, height: 230)
                .clipShape(.rect(cornerRadius: 22))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            Text(page.show.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if !page.show.author.isEmpty {
                Text(page.show.author)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                if let first = resumable(page) ?? page.episodes.first {
                    Button { podcasts.play(first) } label: {
                        Label(resumable(page) != nil ? "Continua" : "Ultima puntata", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                }
                let following = podcasts.isFollowing(page.show.id)
                Button { podcasts.toggleFollow(page.show) } label: {
                    Label(following ? "Seguito" : "Segui", systemImage: following ? "checkmark" : "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
            }
            .padding(.top, 4)
            if let about = page.about, !about.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(about)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsAllAbout ? nil : 3)
                    Button(showsAllAbout ? "Mostra meno" : "Mostra tutto") {
                        withAnimation { showsAllAbout.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The most recent episode of this podcast left halfway.
    private func resumable(_ page: PodcastShowPage) -> PodcastEpisode? {
        podcasts.inProgress.first { $0.showID == page.show.id }
    }

    private func loadMore() async {
        guard !loadingMore, let current = page, let continuation = current.continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let more = try? await InnerTube.shared.moreEpisodes(of: current.show, continuation: continuation) else { return }
        let known = Set(current.episodes.map(\.videoId))
        page?.episodes += more.episodes.filter { !known.contains($0.videoId) }
        page?.continuation = more.continuation
    }
}

// MARK: Episodes

/// An episode: its date and length, title, and how much of it is left; a tap plays it from where
/// it was left.
struct EpisodeRow: View {
    let episode: PodcastEpisode
    /// Shows which podcast it is from (in search and "Continua ad ascoltare").
    var showsShow = false
    /// The menu offers the podcast's page (not on that page itself).
    var linksShow = true

    @ObservedObject private var podcasts = PodcastLibrary.shared
    @EnvironmentObject private var nowPlaying: NowPlayingState

    private var isCurrent: Bool { nowPlaying.currentID == episode.videoId }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button { podcasts.play(episode) } label: {
                HStack(alignment: .top, spacing: 12) {
                    artwork
                    VStack(alignment: .leading, spacing: 4) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(episode.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        status
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Menu {
                EpisodeMenu(episode: episode, linksShow: linksShow)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 44)
                    .contentShape(.rect)
            }
        }
        .contextMenu { EpisodeMenu(episode: episode, linksShow: linksShow) }
    }

    private var artwork: some View {
        CachedImage(url: episode.showArtworkURL ?? episode.artworkURL, pixels: 180) {
            Rectangle().fill(.quaternary)
        }
        .frame(width: 60, height: 60)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            if isCurrent {
                Image(systemName: "waveform")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: nowPlaying.isPlaying)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.45), in: .rect(cornerRadius: 8))
            }
        }
    }

    /// "3 gg fa · 34 min", or the podcast's name first.
    private var caption: String {
        var parts: [String] = []
        if showsShow, !episode.showTitle.isEmpty { parts.append(episode.showTitle) }
        if let date = episode.date { parts.append(date) }
        if let length = podcasts.progress[episode.videoId]?.length ?? episode.listedLength {
            parts.append(Self.length(length))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        if podcasts.isFinished(episode.videoId) {
            Label("Riprodotta", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else if let fraction = podcasts.fraction(of: episode), fraction > 0,
                  let length = podcasts.progress[episode.videoId]?.length ?? episode.listedLength {
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 60)
                Text("Mancano \(Self.length(max(60, length * (1 - fraction))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "34 min", "1 h 5 min".
    static func length(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// An episode's menu: queue, played or not, its podcast, download and share.
struct EpisodeMenu: View {
    let episode: PodcastEpisode
    var linksShow = true

    @ObservedObject private var podcasts = PodcastLibrary.shared
    @EnvironmentObject private var downloads: DownloadManager
    private var player: PlayerController { .shared }
    private var router: AppRouter { .shared }

    var body: some View {
        Button { podcasts.play(episode) } label: {
            Label(podcasts.startTime(for: episode.videoId) != nil ? "Continua" : "Riproduci", systemImage: "play.fill")
        }
        Button {
            podcasts.played(episode)
            player.playNext(track)
        } label: {
            Label("Riproduci dopo", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            podcasts.played(episode)
            player.addToQueue(track)
        } label: {
            Label("Aggiungi in coda", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Divider()
        if podcasts.isFinished(episode.videoId) {
            Button { podcasts.setFinished(false, episode.videoId) } label: {
                Label("Segna come non riprodotta", systemImage: "circle")
            }
        } else {
            Button { podcasts.setFinished(true, episode.videoId) } label: {
                Label("Segna come riprodotta", systemImage: "checkmark.circle")
            }
        }
        if linksShow, let showID = episode.showID, !showID.isEmpty {
            Button { router.page = .podcast(id: showID) } label: {
                Label("Vai al podcast", systemImage: "mic")
            }
        }
        if downloads.isDownloaded(track) {
            Button(role: .destructive) { downloads.remove(track) } label: {
                Label("Rimuovi download", systemImage: "trash")
            }
        } else if downloads.isQueued(track) {
            Button(role: .destructive) { downloads.cancel([track]) } label: {
                Label("Annulla download", systemImage: "xmark.circle")
            }
        } else {
            Button { downloads.download(track) } label: {
                Label("Scarica", systemImage: "arrow.down.circle")
            }
        }
        if let url = track.shareURL {
            ShareLink(item: url) {
                Label("Condividi", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var track: Track {
        var track = episode.track
        track.duration = podcasts.progress[episode.videoId]?.length
        return track
    }
}

// MARK: In the player

/// What the player shows for an episode instead of lyrics: its chapters (a tap jumps there) and
/// its description.
struct EpisodeNotesView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var progress: PlaybackProgress
    @ObservedObject private var podcasts = PodcastLibrary.shared

    var body: some View {
        let episode = podcasts.episode(player.current?.videoId)
        let chapters = episode?.chapters ?? []
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !chapters.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Capitoli")
                                .font(.headline)
                                .padding(.bottom, 6)
                            let current = chapters.lastIndex { $0.time <= progress.currentTime + 0.5 }
                            ForEach(Array(chapters.enumerated()), id: \.element.id) { position, chapter in
                                Button { player.seek(to: chapter.time) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(chapter.time.formattedTime)
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundStyle(Color.white.opacity(0.6))
                                            .frame(minWidth: 52, alignment: .leading)
                                        Text(chapter.title)
                                            .font(.body.weight(position == current ? .bold : .regular))
                                            .foregroundStyle(Color.white.opacity(position == current ? 1 : 0.75))
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 6)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .id(chapter.id)
                            }
                        }
                    }
                    if let notes = episode?.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Descrizione")
                                .font(.headline)
                            Text(Self.linked(notes))
                                .font(.subheadline)
                                .foregroundStyle(Color.white.opacity(0.8))
                                .tint(.white)
                                .textSelection(.enabled)
                        }
                    }
                    if chapters.isEmpty && (episode?.notes ?? "").isEmpty {
                        ContentUnavailableView("Nessuna nota", systemImage: "text.alignleft",
                                               description: Text("Questa puntata non ha capitoli né descrizione."))
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if let current = chapters.last(where: { $0.time <= progress.currentTime }) {
                    proxy.scrollTo(current.id, anchor: .center)
                }
            }
        }
    }

    /// The description with its web addresses as links.
    private static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start..<end].link = url
            result[start..<end].underlineStyle = .single
        }
        return result
    }
}
