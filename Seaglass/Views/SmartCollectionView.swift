import SwiftUI

extension SmartCollectionKind {
    var title: String {
        switch self {
        case .recent: return String(localized: "Ascoltati di recente")
        case .downloaded: return String(localized: "Scaricati")
        case .forgottenFavourites: return String(localized: "Preferiti che ascolti poco")
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .recent: return "Ascoltati di recente"
        case .downloaded: return "Scaricati"
        case .forgottenFavourites: return "Preferiti che ascolti poco"
        }
    }

    var symbol: String {
        switch self {
        case .recent: return "clock.arrow.circlepath"
        case .downloaded: return "arrow.down.to.line.circle.fill"
        case .forgottenFavourites: return "heart.text.square.fill"
        }
    }

    var tint: Color {
        switch self {
        case .recent: return .indigo
        case .downloaded: return .green
        case .forgottenFavourites: return .red
        }
    }
}

/// The smart collections' songs, from the library, the downloads and the listening log as they are now.
@MainActor
enum SmartCollectionSource {
    /// The song plays without a connection: its download, or the user's own file, is on the device.
    static func isOnDevice(_ track: Track) -> Bool {
        Storage.localAudio(for: Library.shared.resolvedTrack(matching: track) ?? track) != nil
    }

    static func forgotten() -> SmartCollections.Forgotten {
        let library = Library.shared
        return SmartCollections.forgottenFavourites(liked: library.liked, events: ListeningLog.shared.events,
                                                    history: library.history) { track in
            (library.resolvedTrack(matching: track) ?? track).videoId
        }
    }

    static func tracks(_ kind: SmartCollectionKind) -> [Track] {
        let library = Library.shared
        switch kind {
        case .recent: return SmartCollections.recent(history: library.history)
        case .downloaded: return SmartCollections.downloaded(library.downloads, isOnDevice: isOnDevice)
        case .forgottenFavourites: return forgotten().tracks
        }
    }

    /// The collection's rule, in words, as it stands now (the listening log's start date included).
    static func rule(_ kind: SmartCollectionKind) -> String {
        switch kind {
        case .recent:
            return String(localized: "Gli ultimi \(SmartCollections.recentLimit) brani che hai avviato, dal più recente, presi dalla cronologia.")
        case .downloaded:
            return String(localized: "I brani scaricati il cui file è su questo dispositivo, dal più recente.")
        case .forgottenFavourites:
            if let since = forgotten().since {
                return String(localized: "Preferiti con al massimo un ascolto di almeno 30 secondi dal \(since.formatted(date: .long, time: .omitted)): da quel giorno Seaglass registra gli ascolti su questo dispositivo.")
            }
            return String(localized: "Su questo dispositivo non ci sono ancora ascolti registrati: compaiono i preferiti che non sono nella cronologia.")
        }
    }
}

/// One smart collection: its rule, its songs, and only those that play offline when asked (or when
/// there is no connection).
struct SmartCollectionView: View {
    let kind: SmartCollectionKind

    @EnvironmentObject private var library: Library
    // Read so the page follows downloads as they finish or are removed.
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.interfaceStyle) private var style
    @State private var offlineOnly = NetworkMonitor.shared.isOffline
    private var player: PlayerController { .shared }

    var body: some View {
        let all = SmartCollectionSource.tracks(kind)
        let available = kind == .downloaded ? all : SmartCollections.availableOffline(all, isOnDevice: SmartCollectionSource.isOnDevice)
        let shown = offlineOnly ? available : all
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(SmartCollectionSource.rule(kind))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(kind.tint)
                    }
                    .font(.footnote)
                    Text("Si aggiorna da sola su questo dispositivo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if kind != .downloaded, !all.isEmpty {
                    Toggle(isOn: $offlineOnly.animation()) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Solo brani disponibili offline")
                            Text("\(available.count) di \(all.count) sul dispositivo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                if !shown.isEmpty {
                    PlayShuffleButtons(tracks: shown, source: kind.title)
                        .listRowSeparator(.hidden)
                }
            }
            .listRowBackground(Color.clear)

            Section {
                if shown.isEmpty {
                    emptyState(all: all)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { position, track in
                    TrackRow(track: track) {
                        player.play(shown, startAt: position, source: kind.title)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(style == .classic ? .hidden : .automatic)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { BrowseBackground() }
        .navigationTitle(kind.title)
        .animation(.smooth(duration: 0.3), value: shown.map(\.id))
    }

    @ViewBuilder private func emptyState(all: [Track]) -> some View {
        if !all.isEmpty {
            ContentUnavailableView("Nessun brano disponibile offline", systemImage: "wifi.slash",
                                   description: Text("Scarica questi brani per ascoltarli senza connessione."))
        } else {
            switch kind {
            case .recent:
                ContentUnavailableView("Ancora nessun ascolto", systemImage: kind.symbol,
                                       description: Text("Qui compaiono gli ultimi \(SmartCollections.recentLimit) brani che avvii, dal più recente."))
            case .downloaded:
                ContentUnavailableView("Nessun brano scaricato", systemImage: "arrow.down.circle",
                                       description: Text("Scarica brani, album o playlist: compaiono qui e si ascoltano anche offline."))
            case .forgottenFavourites:
                if library.liked.isEmpty {
                    ContentUnavailableView("Nessun preferito", systemImage: "heart",
                                           description: Text("Metti il cuore ai brani: quelli che ascolti poco compariranno qui."))
                } else {
                    ContentUnavailableView("Ascolti spesso tutti i tuoi preferiti", systemImage: "heart.circle",
                                           description: Text("Nessun preferito rientra nella regola qui sopra."))
                }
            }
        }
    }
}
