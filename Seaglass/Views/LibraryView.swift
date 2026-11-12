import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.interfaceStyle) private var style
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var importer = PlaylistImporter.shared
    @ObservedObject private var podcasts = PodcastLibrary.shared
    @ObservedObject private var local = LocalMusic.shared
    @State private var showDownloads = false
    /// Opened directly only by CI (see `LaunchScene.opensPlaylistInLibrary`).
    @State private var openedPlaylist: UUID?
    @State private var showNewPlaylist = false
    @State private var showImport = false
    @State private var newName = ""
    @State private var importLink = ""
    @State private var errorText: String?
    @State private var importResult: Playlist?
    @State private var importSuccess: String?
    @State private var showImportFile = false
    @ObservedObject private var account = AccountService.shared
    @State private var paywall: PremiumFeature?
    @State private var showFilePlaylists = false
    @State private var filePlaylists: [PlaylistImportSource] = []
    /// Classic library filter chip (nil = everything).
    @State private var filter: LibraryFilter?
    @State private var gridView = false

    private enum LibraryFilter: Hashable {
        case playlists, podcasts, local
    }

    private var classicPhone: Bool { style == .classic && !ProcessInfo.processInfo.isMacCatalystApp }

    var body: some View {
        NavigationStack {
            Group {
                if classicPhone {
                    classicBody
                } else {
                    seaglassBody
                }
            }
            .scrollContentBackground(.hidden)
            .background { AmbientBackground() }
            .navigationTitle(classicPhone ? "" : (style == .classic ? String(localized: "La tua libreria") : String(localized: "Libreria")))
            .navigationBarTitleDisplayMode(classicPhone ? .inline : .large)
            .toolbar { toolbarContent }
            // Opened directly only by the CI screenshots (see `LaunchScene`).
            .navigationDestination(isPresented: $showDownloads) { DownloadsView() }
            .task {
                if LaunchScene.opensDownloads { showDownloads = true }
                if LaunchScene.opensPlaylistInLibrary { openedPlaylist = library.playlists.first?.id }
            }
            .navigationDestination(item: $openedPlaylist) { PlaylistDetailView(playlistID: $0) }
            .alert("Nuova playlist", isPresented: $showNewPlaylist) {
                TextField("Nome", text: $newName)
                Button("Crea") { library.createPlaylist(named: newName) }
                Button("Annulla", role: .cancel) {}
            }
            .premiumPaywall($paywall)
            .alert("Importa playlist", isPresented: $showImport) {
                TextField("Link della playlist", text: $importLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Importa") { importPlaylist() }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Incolla il link di una playlist o di un album pubblico di Spotify, Apple Music, YouTube o YouTube Music. Se Spotify mostra solo i primi 100 brani, puoi importare una lista completa da file.")
            }
            .alert("Ops", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .alert("Playlist importata", isPresented: Binding(get: { importSuccess != nil },
                                                              set: { if !$0 { importSuccess = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importSuccess ?? "")
            }
            .fileImporter(isPresented: $showImportFile, allowedContentTypes: [.json, .commaSeparatedText, .plainText]) { result in
                importFile(result)
            }
            .sheet(item: $importResult) { playlist in
                NavigationStack {
                    PlaylistImportReviewView(playlistID: playlist.id)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { importResult = nil } } }
                }
                .appEnvironment()
            }
            .sheet(isPresented: $showFilePlaylists) {
                NavigationStack {
                    List(filePlaylists) { source in
                        Button {
                            showFilePlaylists = false
                            importFilePlaylist(source)
                        } label: {
                            HStack {
                                Text(source.name)
                                Spacer()
                                Text("\(source.rows.count) brani").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationTitle("Scegli una playlist")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annulla") { showFilePlaylists = false } } }
                }
                .appEnvironment()
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if classicPhone {
            // Profile + title on the left, as the common streaming apps' library.
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 10) {
                    ProfileButton()
                    Text("La tua libreria")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.pendingTab = .search } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel(Text("Cerca"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newName = ""; showNewPlaylist = true } label: {
                        Label("Nuova playlist", systemImage: "plus")
                    }
                    Button {
                        guard account.unlocks(.playlistLinks) else { paywall = .playlistLinks; return }
                        importLink = ""; showImport = true
                    } label: {
                        Label("Importa da Spotify, Apple Music o YouTube", systemImage: "square.and.arrow.down")
                    }
                    Button { showImportFile = true } label: {
                        Label("Importa playlist da file", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("Nuova playlist"))
            }
        }
    }

    private var seaglassBody: some View {
        List {
            Section {
                NavigationLink { TrackCollectionView(collection: .liked) } label: {
                    shortcut("Preferiti", symbol: "heart.fill", tint: .pink, count: library.liked.count)
                }
                NavigationLink { DownloadsView() } label: {
                    if downloads.batchTotal > 0 {
                        shortcut("Download", symbol: "arrow.down.circle.fill", tint: .blue) {
                            HStack(spacing: 8) {
                                Text("\(downloads.batchTotal - downloads.batchDone) in corso")
                                    .monospacedDigit()
                                ProgressRing(value: downloads.batchFraction, size: 18, showsStop: false)
                            }
                        }
                    } else {
                        shortcut("Download", symbol: "arrow.down.circle.fill", tint: .blue,
                                 count: library.downloads.count)
                    }
                }
                NavigationLink { TrackCollectionView(collection: .history) } label: {
                    shortcut("Cronologia", symbol: "clock.fill", tint: .orange, count: library.history.count)
                }
                NavigationLink { LocalMusicView() } label: {
                    shortcut("File locali", symbol: "internaldrive.fill", tint: .teal, count: local.tracks.count)
                }
                NavigationLink { PodcastsView() } label: {
                    shortcut("Podcast", symbol: "mic.fill", tint: .purple, count: podcasts.followed.count)
                }
            }

            Section {
                playlistActions
                ForEach(library.playlists) { playlist in
                    NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                        PlaylistRow(playlist: playlist)
                    }
                }
                .onDelete { library.deletePlaylists(atOffsets: $0) }
            } header: {
                Text("Playlist")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if library.playlists.isEmpty {
                        Text("Crea una playlist qui, oppure dal tasto ··· accanto a qualsiasi brano.")
                    }
                    Text("Per playlist Spotify oltre 100 brani puoi importare un CSV o il file Playlist1.json dei tuoi dati Spotify.")
                }
            }
        }
    }

    /// Classic: filter pills, Recenti + grid toggle, dense list like the common streaming apps.
    private var classicBody: some View {
        List {
            Section {
                classicFilters
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
                classicSortRow
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            }
            .classicRows(true)

            if gridView {
                Section {
                    classicGrid
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .classicRows(true)
            } else {
                Section {
                    classicListRows
                }
                .classicRows(true)
            }
        }
        .modifier(ClassicList(classic: true))
    }

    @ViewBuilder private var classicListRows: some View {
        if shows(.playlists) {
            NavigationLink { TrackCollectionView(collection: .liked) } label: {
                classicLibraryRow(
                    title: String(localized: "Brani che ti piacciono"),
                    subtitle: playlistSubtitle(library.liked.count),
                    pinned: true
                ) {
                    SymbolArtwork(symbol: "heart.fill",
                                  tint: Color(red: 0.45, green: 0.20, blue: 0.85))
                }
            }
            NavigationLink { DownloadsView() } label: {
                classicLibraryRow(
                    title: String(localized: "Download"),
                    subtitle: String(localized: "\(library.downloads.count) brani")
                ) {
                    SymbolArtwork(symbol: "arrow.down.circle.fill", tint: .blue)
                }
            }
            NavigationLink { TrackCollectionView(collection: .history) } label: {
                classicLibraryRow(
                    title: String(localized: "Cronologia"),
                    subtitle: String(localized: "\(library.history.count) brani")
                ) {
                    SymbolArtwork(symbol: "clock.fill", tint: .orange)
                }
            }
        }
        if shows(.local) {
            NavigationLink { LocalMusicView() } label: {
                classicLibraryRow(
                    title: String(localized: "File locali"),
                    subtitle: String(localized: "\(local.tracks.count) brani")
                ) {
                    SymbolArtwork(symbol: "internaldrive.fill", tint: .teal)
                }
            }
        }
        if shows(.podcasts) {
            NavigationLink { PodcastsView() } label: {
                classicLibraryRow(
                    title: String(localized: "Podcast"),
                    subtitle: String(localized: "\(podcasts.followed.count) seguiti")
                ) {
                    SymbolArtwork(symbol: "mic.fill", tint: .purple)
                }
            }
        }
        if shows(.playlists) {
            ForEach(sortedPlaylists) { playlist in
                NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                    classicLibraryRow(
                        title: playlist.name,
                        subtitle: playlistSubtitle(playlist.tracks.count)
                    ) {
                        PlaylistArtwork(playlist: playlist, cornerRadius: 4)
                    }
                }
            }
            .onDelete { library.deletePlaylists(atOffsets: $0) }
        }
    }

    private func playlistSubtitle(_ count: Int) -> String {
        String(localized: "Playlist · \(count) brani")
    }

    private var classicGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)], spacing: 16) {
            if shows(.playlists) {
                NavigationLink { TrackCollectionView(collection: .liked) } label: {
                    classicGridCell(title: String(localized: "Brani che ti piacciono")) {
                        SymbolArtwork(symbol: "heart.fill",
                                      tint: Color(red: 0.45, green: 0.20, blue: 0.85))
                    }
                }
                .buttonStyle(.plain)
                ForEach(sortedPlaylists) { playlist in
                    NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                        classicGridCell(title: playlist.name) {
                            PlaylistArtwork(playlist: playlist, cornerRadius: 4)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if shows(.podcasts) {
                ForEach(podcasts.followed) { show in
                    NavigationLink { PodcastShowView(id: show.id) } label: {
                        classicGridCell(title: show.title) {
                            CachedImage(url: show.artworkURL, pixels: 300) {
                                Rectangle().fill(ClassicPalette.elevated)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if shows(.local) {
                NavigationLink { LocalMusicView() } label: {
                    classicGridCell(title: String(localized: "File locali")) {
                        SymbolArtwork(symbol: "internaldrive.fill", tint: .teal)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func classicGridCell<Artwork: View>(title: String, @ViewBuilder artwork: () -> Artwork) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork()
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 4))
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var classicFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ClassicPill(title: "Playlist", selected: filter == .playlists) {
                    filter = filter == .playlists ? nil : .playlists
                }
                ClassicPill(title: "Podcast", selected: filter == .podcasts) {
                    filter = filter == .podcasts ? nil : .podcasts
                }
                ClassicPill(title: "File locali", selected: filter == .local) {
                    filter = filter == .local ? nil : .local
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var classicSortRow: some View {
        HStack {
            Label("Recenti", systemImage: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                gridView.toggle()
            } label: {
                Image(systemName: gridView ? "list.bullet" : "square.grid.2x2")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(gridView ? "Elenco" : "Griglia"))
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var sortedPlaylists: [Playlist] {
        PlaylistUsage.sorted(library.playlists)
    }

    private func shows(_ kind: LibraryFilter) -> Bool {
        filter == nil || filter == kind
    }

    private func classicLibraryRow<Artwork: View>(title: String, subtitle: String, pinned: Bool = false,
                                                  @ViewBuilder artwork: () -> Artwork) -> some View {
        HStack(spacing: 12) {
            artwork()
                .frame(width: 64, height: 64)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(ClassicPalette.accent)
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(ClassicPalette.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var playlistActions: some View {
        Button {
            newName = ""
            showNewPlaylist = true
        } label: {
            Label("Nuova playlist", systemImage: "plus.circle.fill")
        }
        Button {
            guard account.unlocks(.playlistLinks) else {
                paywall = .playlistLinks
                return
            }
            importLink = ""
            showImport = true
        } label: {
            if let status = importer.status {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(status).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Label("Importa da Spotify, Apple Music o YouTube", systemImage: "square.and.arrow.down.fill")
                    if !account.unlocks(.playlistLinks) {
                        Spacer()
                        PremiumBadge()
                    }
                }
            }
        }
        .disabled(importer.status != nil)
        Button { showImportFile = true } label: {
            Label("Importa playlist da file", systemImage: "doc.badge.plus")
        }
        .disabled(importer.status != nil)
    }

    private func shortcut(_ title: LocalizedStringKey, symbol: String, tint: Color, count: Int) -> some View {
        shortcut(title, symbol: symbol, tint: tint) {
            Text("\(count)")
        }
    }

    @ViewBuilder
    private func shortcut<Detail: View>(_ title: LocalizedStringKey, symbol: String, tint: Color,
                                        @ViewBuilder detail: () -> Detail) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint.gradient, in: .rect(cornerRadius: 10))
            Text(title).font(.body.weight(.medium))
            Spacer()
            detail().foregroundStyle(.secondary)
        }
    }

    private func importPlaylist() {
        let link = importLink
        Task {
            do {
                let outcome = try await importer.importPlaylist(from: link)
                if outcome.playlist.importReport != nil { importResult = outcome.playlist }
                else { importSuccess = "\"\(outcome.playlist.name)\": \(outcome.playlist.countLabel)." }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let sources = try PlaylistImportFile.read(Data(contentsOf: url), fileName: url.lastPathComponent)
            guard !sources.isEmpty else { throw PlaylistImportFileError.unsupported }
            if sources.count == 1 { importFilePlaylist(sources[0]) }
            else { filePlaylists = sources; showFilePlaylists = true }
        } catch let error as CocoaError where error.code == .userCancelled {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importFilePlaylist(_ source: PlaylistImportSource) {
        Task {
            do { importResult = try await importer.importPlaylist(from: source).playlist }
            catch { errorText = error.localizedDescription }
        }
    }
}

enum TrackCollection {
    case liked, downloads, history

    var title: String {
        switch self {
        case .liked: return String(localized: "Preferiti")
        case .downloads: return String(localized: "Download")
        case .history: return String(localized: "Cronologia")
        }
    }
}

/// Preferiti, Download and Cronologia.
struct TrackCollectionView: View {
    let collection: TrackCollection

    @EnvironmentObject private var library: Library
    private var player: PlayerController { .shared }
    @EnvironmentObject private var downloads: DownloadManager
    @State private var editMode: EditMode = .inactive

    private var tracks: [Track] {
        switch collection {
        case .liked: return library.liked
        case .downloads: return library.downloads
        case .history: return library.history
        }
    }

    private var canReorder: Bool { collection == .liked && tracks.count >= 2 }

    var body: some View {
        List {
            if !tracks.isEmpty {
                PlayShuffleButtons(tracks: tracks, source: collection.title)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { position, track in
                TrackRow(track: track, remove: { delete(IndexSet(integer: position)) }) {
                    player.play(tracks, startAt: position, source: collection.title)
                }
                .allowsHitTesting(!editMode.isEditing)
                .listRowBackground(Color.clear)
            }
            .onDelete(perform: delete)
            .onMove { source, destination in
                // Only favourites keep a custom order; downloads and history are sorted by date.
                guard collection == .liked else { return }
                library.moveLiked(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { AmbientBackground() }
        .environment(\.editMode, $editMode)
        .overlay {
            if tracks.isEmpty { emptyState }
        }
        .navigationTitle(collection.title)
        .toolbar { collectionToolbar }
    }

    @ToolbarContentBuilder private var collectionToolbar: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fine") { withAnimation { editMode = .inactive } }
            }
        } else if canReorder {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { editMode = .active }
                } label: {
                    Label("Riordina i brani", systemImage: "line.3.horizontal")
                }
            }
        }
        if collection == .history && !tracks.isEmpty && !editMode.isEditing {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Svuota") { library.clearHistory() }
            }
        }
    }

    private func moveLiked(from source: IndexSet, to destination: Int) {
        library.moveLiked(fromOffsets: source, toOffset: destination)
    }

    @ViewBuilder private var emptyState: some View {
        switch collection {
        case .liked:
            ContentUnavailableView("Nessun preferito", systemImage: "heart",
                                   description: Text("Tocca il cuore nel player, o scorri un brano verso destra."))
        case .downloads:
            ContentUnavailableView("Nessun download", systemImage: "arrow.down.circle",
                                   description: Text("Tocca ··· accanto a un brano e scegli Scarica."))
        case .history:
            ContentUnavailableView("Cronologia vuota", systemImage: "clock",
                                   description: Text("I brani che ascolti appariranno qui."))
        }
    }

    private func delete(_ offsets: IndexSet) {
        let selected = offsets.map { tracks[$0] }
        switch collection {
        case .liked:
            for track in selected { library.toggleLike(track) }
        case .downloads:
            for track in selected { downloads.remove(track) }
        case .history:
            library.removeFromHistory(selected)
        }
    }
}
