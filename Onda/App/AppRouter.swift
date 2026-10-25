import Combine
import SwiftUI

/// App-wide presentation state: the full-screen player and the "add to playlist" sheet,
/// which can be asked for from any song menu.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var showPlayer = false
    @Published var trackToAdd: Track?

    private init() {}

    /// Binding for the presenter that is on top: the player while it is open, the tab view otherwise.
    func addToPlaylistBinding(fromPlayer: Bool) -> Binding<Track?> {
        Binding(
            get: { self.showPlayer == fromPlayer ? self.trackToAdd : nil },
            set: { self.trackToAdd = $0 }
        )
    }
}
