import SwiftUI

enum AppTab: Hashable {
    case home, library, settings, search
}

/// The Mac's sidebar, as Apple Music's: search, the Home, the library's parts and every playlist.
enum MacSection: Hashable {
    case search, home, library, liked, history, downloads, podcasts, settings
    case playlist(UUID)

    init(_ tab: AppTab) {
        switch tab {
        case .home: self = .home
        case .library: self = .library
        case .settings: self = .settings
        case .search: self = .search
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var updater: AppUpdater
    @EnvironmentObject private var library: Library
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @State private var selection: AppTab = .home
    @State private var macSelection: MacSection = .home

    private static let isMac = ProcessInfo.processInfo.isMacCatalystApp

    var body: some View {
        tabs
        // The cover is see-through: `PlayerCard` draws the player as a card that grows out of the
        // mini player, with the app still visible behind it.
        .fullScreenCover(isPresented: $router.showPlayer) {
            PlayerCard()
                .appEnvironment()
                .presentationBackground(.clear)
        }
        .sheet(item: router.addToPlaylistBinding(fromPlayer: false)) { track in
            AddToPlaylistSheet(track: track).appEnvironment()
        }
        .sheet(item: router.pageBinding(fromPlayer: false)) { page in
            MusicPageSheet(page: page).appEnvironment()
        }
        .sheet(item: $router.mixTarget) { target in
            PlaylistMixView(playlistID: target.playlistID, opensFirst: target.opensFirst, opensOptions: target.options,
                            opensEditing: target.editing)
                .appEnvironment()
        }
        .trackToasts(.root)
        .task {
            LaunchScene.apply(select: { tab in
                selection = tab
                macSelection = MacSection(tab)
            })
        }
        .background { PlayerKeyboardShortcuts() }
        // Outermost, so the player and sheets presented above inherit it too.
        .tint(accent.color)
        .downloadErrorAlert(isActive: !router.showPlayer)
        .appUpdatePresentation(isActive: !router.showPlayer)
    }
}

extension RootView {
    @ViewBuilder fileprivate var tabs: some View {
        if Self.isMac {
            macTabs
        } else {
            phoneTabs
        }
    }

    private var phoneTabs: some View {
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
        // On an iPad: tabs at the top that can become a sidebar, as in the Music app.
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer { router.openPlayer() }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    router.miniPlayerFrame = frame
                }
        }
    }

    /// On a Mac, Apple Music's sidebar (search first, the Home, the library, the playlists) and its
    /// player bar along the bottom.
    private var macTabs: some View {
        NavigationSplitView {
            List(selection: Binding<MacSection?>(
                get: { macSelection },
                set: { if let selection = $0 { macSelection = selection } }
            )) {
                macSidebarItem("Cerca", symbol: "magnifyingglass", section: .search)
                macSidebarItem("Home", symbol: "house", section: .home)
                Section("Libreria") {
                    macSidebarItem("Libreria", symbol: "square.stack", section: .library)
                    macSidebarItem("Preferiti", symbol: "heart", section: .liked)
                    macSidebarItem("Cronologia", symbol: "clock", section: .history)
                    macSidebarItem("Download", symbol: "arrow.down.circle", section: .downloads)
                    macSidebarItem("Podcast", symbol: "mic", section: .podcasts)
                }
                Section("Playlist") {
                    ForEach(library.playlists) { playlist in
                        NavigationLink(value: MacSection.playlist(playlist.id)) {
                            HStack(spacing: 10) {
                                PlaylistArtwork(playlist: playlist, size: 28, cornerRadius: 5)
                                    .accessibilityHidden(true)
                                Text(playlist.name).lineLimit(1)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                macSidebarItem("Impostazioni", symbol: "gearshape", section: .settings)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            macDetail
                .id(macSelection)
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacPlayerBar()
                .background(.bar)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    router.miniPlayerFrame = frame
                }
        }
        // A deleted playlist's page goes with it.
        .onChange(of: library.playlists.map(\.id)) { _, ids in
            if case .playlist(let id) = macSelection, !ids.contains(id) { macSelection = .home }
        }
    }

    private func macSidebarItem(_ title: LocalizedStringKey, symbol: String, section: MacSection) -> some View {
        NavigationLink(value: section) { Label(title, systemImage: symbol) }
    }

    @ViewBuilder private var macDetail: some View {
        switch macSelection {
        case .search: SearchView()
        case .home: HomeView()
        case .library: LibraryView()
        case .liked: NavigationStack { TrackCollectionView(collection: .liked) }
        case .history: NavigationStack { TrackCollectionView(collection: .history) }
        case .downloads: NavigationStack { DownloadsView() }
        case .podcasts: NavigationStack { PodcastsView() }
        case .playlist(let id): NavigationStack { PlaylistDetailView(playlistID: id) }
        case .settings: SettingsView()
        }
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
