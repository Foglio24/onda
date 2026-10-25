import SwiftUI

enum AppTab: Hashable {
    case home, library, settings, search
}

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @State private var selection: AppTab = .home
    @Namespace private var transition

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("Libreria", systemImage: "square.stack.fill", value: AppTab.library) {
                LibraryView()
            }
            Tab("Impostazioni", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer { router.showPlayer = true }
                .matchedTransitionSource(id: "now-playing", in: transition)
        }
        .fullScreenCover(isPresented: $router.showPlayer) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "now-playing", in: transition))
        }
        .sheet(item: router.addToPlaylistBinding(fromPlayer: false)) { track in
            AddToPlaylistSheet(track: track)
        }
        // Outermost, so the player and sheets presented above inherit it too.
        .tint(accent.color)
    }
}
