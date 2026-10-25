import SwiftUI

enum AppTab: Hashable {
    case home, library, settings, search
}

struct RootView: View {
    @State private var selection: AppTab = .home
    @State private var showPlayer = false
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
            MiniPlayer { showPlayer = true }
                .matchedTransitionSource(id: "now-playing", in: transition)
        }
        .fullScreenCover(isPresented: $showPlayer) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "now-playing", in: transition))
        }
    }
}
