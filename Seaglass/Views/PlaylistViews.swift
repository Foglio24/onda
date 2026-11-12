import PhotosUI
import SwiftUI

struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 14) {
            PlaylistArtwork(playlist: playlist, size: 56, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(playlist.countLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID

    @EnvironmentObject private var library: Library
    private var player: PlayerController { .shared }
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var showRename = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var confirmRemoveDownloads = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showMix = false
    @ObservedObject private var account = AccountService.shared
    /// The Mix is a Premium feature of its own: where Premium is needed and there is none, it explains it.
    @State private var paywall: PremiumFeature?

    private func openMix() {
        if account.unlocks(.playlistMix) { showMix = true } else { paywall = .playlistMix }
    }

    /// Reordering: the songs show handles to drag them by (and the delete button), and are not
    /// played, swiped or long-pressed meanwhile.
    @State private var editMode: EditMode = .inactive
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @Environment(\.interfaceStyle) private var style

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        Group {
            if let playlist = library.playlist(playlistID) {
                List {
                    header(playlist)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    if let report = playlist.importReport,
                       !report.pending.isEmpty || report.mayBeTruncated || !report.ignored.isEmpty {
                        NavigationLink { PlaylistImportReviewView(playlistID: playlistID) } label: {
                            Label {
                                if report.pending.isEmpty { Text("Riepilogo importazione") }
                                else { Text("\(report.pending.count) brani da controllare") }
                            } icon: {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }

                    if playlist.tracks.isEmpty {
                        Group {
                            if playlist.importReport?.pending.isEmpty == false {
                                Text("Nessun brano trovato automaticamente. Apri il riepilogo per scegliere le alternative.")
                            } else {
                                Text("La playlist è vuota. Aggiungi brani con il tasto ··· accanto a ogni canzone, oppure scorrendo un brano verso sinistra e toccando «Cambia».")
                            }
                        }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { position, track in
                        TrackRow(track: track, remove: {
                            library.removeTracks(atOffsets: IndexSet(integer: position), from: playlistID)
                        }) {
                            player.play(playlist.tracks, startAt: position, source: playlist.name, playlist: playlist.id)
                        }
                        .allowsHitTesting(!isEditing)
                        .listRowBackground(Color.clear)
                    }
                    .onDelete { library.removeTracks(atOffsets: $0, from: playlistID) }
                    .onMove { library.moveTracks(fromOffsets: $0, toOffset: $1, in: playlistID) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
                .toolbar {
                    if isEditing {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fine") { withAnimation { editMode = .inactive } }
                        }
                    } else if playlist.tracks.count >= 2 {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { openMix() } label: {
                                Label("Mix", systemImage: "slider.horizontal.3")
                            }
                        }
                    }
                    if !isEditing {
                        ToolbarItem(placement: .topBarTrailing) { toolbarMenu(playlist) }
                    }
                }
            } else {
                ContentUnavailableView("Playlist eliminata", systemImage: "music.note.list")
            }
        }
        .background { AmbientBackground() }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { PlaylistUsage.noteOpened(playlistID) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .sheet(isPresented: $showMix) { PlaylistMixView(playlistID: playlistID).appEnvironment() }
        .premiumPaywall($paywall)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    library.setCover(data, for: playlistID)
                }
                photoItem = nil
            }
        }
        .alert("Rinomina playlist", isPresented: $showRename) {
            TextField("Nome", text: $newName)
            Button("Salva") { library.renamePlaylist(playlistID, to: newName) }
            Button("Annulla", role: .cancel) {}
        }
        .confirmationDialog("Eliminare questa playlist?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) {
                library.deletePlaylist(playlistID)
                dismiss()
            }
        }
        .confirmationDialog("Rimuovere i brani scaricati di questa playlist?", isPresented: $confirmRemoveDownloads,
                            titleVisibility: .visible) {
            Button("Rimuovi download", role: .destructive) {
                if let playlist = library.playlist(playlistID) { downloads.removeAll(playlist.tracks) }
            }
        }
    }

    private func toolbarMenu(_ playlist: Playlist) -> some View {
        Menu {
            Button { showPhotoPicker = true } label: {
                Label("Cambia copertina", systemImage: "photo")
            }
            if playlist.coverFile != nil {
                Button { library.removeCover(for: playlistID) } label: {
                    Label("Usa le copertine dei brani", systemImage: "square.grid.2x2")
                }
            }
            Button {
                newName = playlist.name
                showRename = true
            } label: {
                Label("Rinomina", systemImage: "pencil")
            }
            if playlist.tracks.count >= 2 {
                Button { withAnimation { editMode = .active } } label: {
                    Label("Riordina i brani", systemImage: "arrow.up.arrow.down")
                }
            }
            if playlist.tracks.contains(where: { downloads.isDownloaded($0) }) {
                Button(role: .destructive) { confirmRemoveDownloads = true } label: {
                    Label("Rimuovi download", systemImage: "arrow.down.circle.dotted")
                }
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Elimina playlist", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    private func header(_ playlist: Playlist) -> some View {
        let classic = style == .classic
        return VStack(spacing: classic ? 16 : 14) {
            Button { showPhotoPicker = true } label: {
                PlaylistArtwork(playlist: playlist, size: classic ? 232 : 220, cornerRadius: classic ? 4 : 22)
                    .overlay(alignment: .bottomTrailing) {
                        if !classic {
                            Image(systemName: "camera.fill")
                                .font(.footnote.weight(.semibold))
                                .padding(9)
                                .styledSurface(in: .circle)
                                .padding(10)
                        }
                    }
                    .shadow(color: .black.opacity(classic ? 0.45 : 0.35), radius: classic ? 18 : 24, y: classic ? 8 : 12)
            }
            .buttonStyle(.plain)

            // The classic style has the name and the summary on the left, under the cover.
            VStack(alignment: classic ? .leading : .center, spacing: classic ? 6 : 4) {
                Text(playlist.name)
                    .font(classic ? .largeTitle.bold() : .title2.bold())
                    .multilineTextAlignment(classic ? .leading : .center)
                Text(summary(playlist))
                    .font(.subheadline)
                    .foregroundStyle(classic ? ClassicPalette.secondaryText : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: classic ? .leading : .center)
            if !playlist.tracks.isEmpty {
                if classic {
                    classicActionRow(playlist)
                } else {
                    PlayShuffleButtons(tracks: playlist.tracks, source: playlist.name, playlist: playlist.id)
                    if playlist.tracks.count >= 2 { mixRow(playlist) }
                    downloadButton(playlist)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Classic playlist chrome: download / share / menu on the left, shuffle + green play on the right.
    private func classicActionRow(_ playlist: Playlist) -> some View {
        let status = downloads.status(of: playlist.tracks)
        let isComplete = status.total > 0 && status.saved == status.total
        return HStack(spacing: 16) {
            Button {
                if status.inProgress > 0 { downloads.cancel(playlist.tracks) }
                else if !isComplete { downloads.downloadAll(playlist.tracks) }
            } label: {
                Group {
                    if status.inProgress > 0 {
                        ProgressRing(value: status.fraction, size: 22)
                    } else {
                        Image(systemName: isComplete ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(isComplete ? ClassicPalette.accent : ClassicPalette.secondaryText)
                    }
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(playlist.tracks.isEmpty || (isComplete && status.inProgress == 0))
            .accessibilityLabel(Text(isComplete ? "Playlist scaricata" : "Scarica tutta la playlist"))

            ShareLink(item: playlistShareText(playlist)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title2)
                    .foregroundStyle(ClassicPalette.secondaryText)
                    .frame(width: 36, height: 36)
            }

            toolbarMenu(playlist)
                .font(.title2)
                .foregroundStyle(ClassicPalette.secondaryText)

            Spacer(minLength: 0)

            if playlist.tracks.count >= 2 {
                Button { openMix() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ClassicPalette.secondaryText)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Mix"))
            }
            PlayShuffleButtons(tracks: playlist.tracks, source: playlist.name, playlist: playlist.id,
                               fillsWidth: false)
        }
    }

    private func playlistShareText(_ playlist: Playlist) -> String {
        "\(playlist.name) · \(playlist.countLabel)"
    }

    /// The playlist's Mix on or off in one tap, and its transitions (the Mix sheet). On, every
    /// transition of the playlist is mixed when it plays: the ones designed in the sheet, AutoMix's
    /// choice for the others, whatever "Transizioni tra brani" says.
    private func mixRow(_ playlist: Playlist) -> some View {
        let isOn = (playlist.mix?.enabled ?? false) && account.unlocks(.playlistMix)
        return VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    guard account.unlocks(.playlistMix) else {
                        paywall = .playlistMix
                        return
                    }
                    library.setMixEnabled(!isOn, for: playlistID)
                    player.applyTransitionPreference()
                } label: {
                    HStack(spacing: 6) {
                        Label(isOn ? "Mix attivo" : "Attiva il Mix",
                              systemImage: isOn ? "checkmark.circle.fill" : "slider.horizontal.3")
                        BetaBadge()
                    }
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .styledSurface(in: .capsule, interactive: true, tint: isOn ? accent.color.opacity(0.55) : nil)
                .accessibilityAddTraits(isOn ? .isSelected : [])

                Button { openMix() } label: {
                    HStack(spacing: 6) {
                        Label("Transizioni", systemImage: "arrow.left.arrow.right")
                        BetaBadge()
                    }
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .styledSurface(in: .capsule, interactive: true)
            }
            Text(isOn
                 ? "Quando ascolti questa playlist i brani sono mixati: con le transizioni che hai creato, e con AutoMix dove non ne hai create."
                 : "Mixa tutti i brani di questa playlist quando la ascolti, anche con AutoMix spento.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// One tap saves the whole playlist, with the Music app's progress ring while it runs.
    /// Last.fm songs are resolved by the download queue, rather than silently skipped.
    private func downloadButton(_ playlist: Playlist) -> some View {
        CollectionDownloadButton(tracks: playlist.tracks,
                                 downloadTitle: String(localized: "Scarica tutta la playlist"),
                                 doneTitle: String(localized: "Playlist scaricata"), verticalPadding: 11)
            .buttonStyle(.plain)
            .styledSurface(in: .capsule, interactive: true)
    }

    private func summary(_ playlist: Playlist) -> String {
        let total = playlist.tracks.compactMap(\.duration).reduce(0, +)
        guard total > 0 else { return playlist.countLabel }
        let minutes = Int(total / 60)
        let length = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return "\(playlist.countLabel) · \(length)"
    }
}

/// Sheet opened by "Aggiungi a playlist…": tick the playlists the song belongs to, or create a new one.
struct AddToPlaylistSheet: View {
    let track: Track

    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ArtworkView(track: track, size: 48, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.headline).lineLimit(1)
                            Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }

                Section {
                    Button { library.toggleLike(track) } label: {
                        HStack {
                            Label("Preferiti", systemImage: "heart.fill")
                                .foregroundStyle(.pink)
                            Spacer()
                            if library.isLiked(track) { checkmark }
                        }
                    }
                    Button {
                        newName = ""
                        showNew = true
                    } label: {
                        Label("Nuova playlist", systemImage: "plus")
                    }
                }

                if !library.playlists.isEmpty {
                    Section("Le tue playlist") {
                        ForEach(library.playlists) { playlist in
                            Button { library.toggle(track, in: playlist.id) } label: {
                                HStack {
                                    PlaylistRow(playlist: playlist)
                                    Spacer()
                                    if library.contains(track, in: playlist.id) { checkmark }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Aggiungi a playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .alert("Nuova playlist", isPresented: $showNew) {
                TextField("Nome", text: $newName)
                Button("Crea") { library.createPlaylist(named: newName, tracks: [track]) }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("\"\(track.title)\" verrà aggiunto alla nuova playlist.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var checkmark: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.tint)
    }
}
