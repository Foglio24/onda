import Combine
import SwiftUI

/// A YouTube Music page that can be opened from anywhere (song menus, the player, search).
enum MusicPage: Identifiable, Hashable {
    /// `id` is nil for songs known only by artist name (e.g. from Last.fm): the page looks it up.
    case artist(id: String?, name: String)
    case album(id: String)
    case playlist(id: String, title: String)
    /// "Informazioni sul brano": a song's release date, label, credits and so on.
    case song(Track)

    init?(_ item: MusicItem) {
        switch item.kind {
        case .artist: self = .artist(id: item.id, name: item.title)
        case .album: self = .album(id: item.id)
        case .playlist: self = .playlist(id: item.id, title: item.title)
        case .song: return nil
        }
    }

    var id: String {
        switch self {
        case .artist(let id, let name): return "artist-\(id ?? name)"
        case .album(let id): return "album-\(id)"
        case .playlist(let id, _): return "playlist-\(id)"
        case .song(let track): return "song-\(track.id)"
        }
    }
}

/// App-wide presentation state: the full-screen player, the "add to playlist" sheet and artist,
/// album and playlist pages, which can be asked for from any song menu.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    /// Who shows sheets right now: the one on top.
    enum Presenter {
        case root, player, page
    }

    @Published var showPlayer = false
    @Published var trackToAdd: Track?
    @Published var page: MusicPage?
    /// A search to run when the Search tab appears (used by `LaunchScene`).
    @Published var pendingSearch: String?

    private init() {}

    private var topPresenter: Presenter {
        if page != nil { return .page }
        return showPlayer ? .player : .root
    }

    /// Binding for the presenter that is on top: the player while it is open, the tab view otherwise.
    func addToPlaylistBinding(fromPlayer: Bool) -> Binding<Track?> {
        addToPlaylistBinding(for: fromPlayer ? .player : .root)
    }

    func addToPlaylistBinding(for presenter: Presenter) -> Binding<Track?> {
        Binding(
            get: { self.topPresenter == presenter ? self.trackToAdd : nil },
            set: { self.trackToAdd = $0 }
        )
    }

    /// Pages open over the player while it is shown, over the tabs otherwise.
    func pageBinding(fromPlayer: Bool) -> Binding<MusicPage?> {
        Binding(
            get: { self.showPlayer == fromPlayer ? self.page : nil },
            set: { self.page = $0 }
        )
    }
}
