import SwiftUI

enum AppTab: Hashable {
    case home, library, settings, search
}

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var updater: AppUpdater
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @State private var selection: AppTab = .home

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
            MiniPlayer { router.openPlayer() }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    router.miniPlayerFrame = frame
                }
        }
        // The cover is see-through: `PlayerCard` draws the player as a card that grows out of the
        // mini player, with the app still visible behind it.
        .fullScreenCover(isPresented: $router.showPlayer) {
            PlayerCard()
                .presentationBackground(.clear)
        }
        .sheet(item: router.addToPlaylistBinding(fromPlayer: false)) { track in
            AddToPlaylistSheet(track: track)
        }
        .sheet(isPresented: $updater.showsNotice) {
            UpdateSheet()
        }
        .sheet(item: router.pageBinding(fromPlayer: false)) { page in
            MusicPageSheet(page: page)
        }
        .sheet(item: $router.mixTarget) { target in
            PlaylistMixView(playlistID: target.playlistID, opensFirst: target.opensFirst, opensOptions: target.options,
                            opensEditing: target.editing)
        }
        .trackToasts(.root)
        .task { LaunchScene.apply(select: { selection = $0 }) }
        // Outermost, so the player and sheets presented above inherit it too.
        .tint(accent.color)
        .downloadErrorAlert(isActive: !router.showPlayer)
    }
}

/// Attach to each top-level presenter so failures are visible with the player open too.
private struct DownloadErrorAlert: ViewModifier {
    @EnvironmentObject private var downloads: DownloadManager
    let isActive: Bool

    func body(content: Content) -> some View {
        content.alert("Download non riuscito", isPresented: Binding(
            get: { isActive && downloads.lastError != nil },
            set: { if !$0 && isActive { downloads.dismissError() } }
        )) {
            Button("OK", role: .cancel) { downloads.dismissError() }
        } message: {
            Text(downloads.lastError ?? "")
        }
    }
}

extension View {
    func downloadErrorAlert(isActive: Bool) -> some View {
        modifier(DownloadErrorAlert(isActive: isActive))
    }
}
