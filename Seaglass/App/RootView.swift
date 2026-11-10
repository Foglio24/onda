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
    @StateObject private var sidebarCovers = SidebarCovers()

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

    /// On a Mac, Apple Music's sidebar (search first, the Home, the library, the playlists), the
    /// system's own in Liquid Glass, and its player bar floating in glass along the bottom of every
    /// page, the page scrolling under it.
    private var macTabs: some View {
        TabView(selection: $macSelection) {
            Tab(value: MacSection.search, role: .search) {
                macPage { SearchView() }
            }
            Tab("Home", systemImage: "house", value: MacSection.home) {
                macPage { HomeView() }
            }
            TabSection("Libreria") {
                Tab("Libreria", systemImage: "square.stack", value: MacSection.library) {
                    macPage { LibraryView() }
                }
                Tab("Preferiti", systemImage: "heart", value: MacSection.liked) {
                    macPage { NavigationStack { TrackCollectionView(collection: .liked) } }
                }
                Tab("Cronologia", systemImage: "clock", value: MacSection.history) {
                    macPage { NavigationStack { TrackCollectionView(collection: .history) } }
                }
                Tab("Download", systemImage: "arrow.down.circle", value: MacSection.downloads) {
                    macPage { NavigationStack { DownloadsView() } }
                }
                Tab("Podcast", systemImage: "mic", value: MacSection.podcasts) {
                    macPage { NavigationStack { PodcastsView() } }
                }
            }
            TabSection("Playlist") {
                ForEach(library.playlists) { playlist in
                    Tab(value: MacSection.playlist(playlist.id)) {
                        macPage { NavigationStack { PlaylistDetailView(playlistID: playlist.id) } }
                    } label: {
                        Label {
                            Text(playlist.name)
                        } icon: {
                            if let cover = sidebarCovers.covers[playlist.id] {
                                Image(uiImage: cover).renderingMode(.original)
                            } else {
                                Image(systemName: "music.note.list")
                            }
                        }
                    }
                }
            }
            Tab("Impostazioni", systemImage: "gearshape", value: MacSection.settings) {
                macPage { SettingsView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .task(id: library.playlists.map(\.sidebarCoverKey)) { await sidebarCovers.update(library.playlists) }
        // A deleted playlist's page goes with it.
        .onChange(of: library.playlists.map(\.id)) { _, ids in
            if case .playlist(let id) = macSelection, !ids.contains(id) { macSelection = .home }
        }
    }

    /// A page of the Mac's window, with the player bar over its bottom. An overlay, so it stays on
    /// top of the pages pushed inside it too (a playlist opened from the library); the safe area
    /// makes room for it at the end of the page.
    private func macPage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .safeAreaPadding(.bottom, MacPlayerBar.height + 24)
            .overlay(alignment: .bottom) {
                MacPlayerBar()
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        router.miniPlayerFrame = frame
                    }
            }
    }
}

/// The playlists' covers as small pictures for the Mac's sidebar, whose items take an image (the
/// system's sidebar draws them, not SwiftUI): the custom cover, or the first four songs' artwork.
@MainActor
final class SidebarCovers: ObservableObject {
    @Published private(set) var covers: [UUID: UIImage] = [:]
    private static let side: CGFloat = 22

    func update(_ playlists: [Playlist]) async {
        var updated: [UUID: UIImage] = [:]
        for playlist in playlists {
            if Task.isCancelled { return }
            if let cover = await Self.cover(of: playlist) { updated[playlist.id] = cover }
        }
        covers = updated
    }

    private static func cover(of playlist: Playlist) async -> UIImage? {
        let pixels = Int(side * 3)
        if let custom = playlist.customCoverURL {
            return await ImageCache.shared.image(for: custom, pixels: pixels).map(rounded)
        }
        var images: [UIImage] = []
        for track in playlist.tracks.prefix(4) {
            guard let url = track.mediumArtworkURL, let image = await ImageCache.shared.image(for: url, pixels: pixels) else { continue }
            images.append(image)
        }
        guard let first = images.first else { return nil }
        guard images.count == 4 else { return rounded(first) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let size = CGSize(width: side, height: side)
        let grid = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            for (index, image) in images.enumerated() {
                let half = side / 2
                image.draw(in: CGRect(x: CGFloat(index % 2) * half, y: CGFloat(index / 2) * half, width: half, height: half))
            }
        }
        return rounded(grid)
    }

    private static func rounded(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            UIBezierPath(roundedRect: rect, cornerRadius: 5).addClip()
            image.draw(in: rect)
        }.withRenderingMode(.alwaysOriginal)
    }
}

private extension Playlist {
    /// Changes when the sidebar's cover of the playlist would.
    var sidebarCoverKey: String {
        ([id.uuidString, coverFile ?? ""] + tracks.prefix(4).map(\.id)).joined(separator: "|")
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
