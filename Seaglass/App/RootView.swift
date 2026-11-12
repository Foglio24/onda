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
    @AppStorage(Preferences.interfaceStyle) private var style: InterfaceStyle = .seaglass
    @State private var selection: AppTab = .home
    @State private var macSelection: MacSection = .home
    @State private var visitedSections: Set<MacSection> = []

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
        .sheet(isPresented: $router.showSettings) {
            SettingsView()
                .appEnvironment()
                .classicPageSheet()
                .presentationBackground(ClassicPalette.background)
        }
        .sheet(isPresented: $router.showProfileMenu) {
            ClassicProfileSheet().appEnvironment()
        }
        .sheet(item: $router.trackActions) { track in
            TrackActionSheet(track: track).appEnvironment()
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
        } else if style == .classic {
            ClassicTabs(selection: $selection)
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

    /// On a Mac, Apple Music's layout on macOS 26: a sidebar floating in Liquid Glass along the
    /// window's left (search, the Home, the library, the playlists, Settings), with the window's
    /// buttons on it, and the player bar floating in glass along the bottom, the page scrolling
    /// under it. In the classic style the same chrome is black and flat, in green. The sidebar is
    /// the app's own: the system's (TabView, NavigationSplitView) is opaque in an iPad app on a Mac.
    private var macTabs: some View {
        let classic = style == .classic
        return macPages
            .safeAreaPadding(.bottom, MacPlayerBar.height + 24)
            .padding(.leading, MacSidebar.width + 2 * MacSidebar.inset)
            .background {
                (classic ? ClassicPalette.background : Color(.systemBackground)).ignoresSafeArea()
            }
            .overlay(alignment: .bottom) {
                MacPlayerBar()
                    .modifier(MacPlayerBarChrome(classic: classic))
                    .padding(.leading, MacSidebar.width + 2 * MacSidebar.inset + 8)
                    .padding(.trailing, 18)
                    .padding(.bottom, 14)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        router.miniPlayerFrame = frame
                    }
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    MacSidebar(selection: $macSelection, top: proxy.safeAreaInsets.top)
                        .padding(MacSidebar.inset)
                }
                .ignoresSafeArea()
            }
            // A deleted playlist's page goes with it.
            .onChange(of: library.playlists.map(\.id)) { _, ids in
                if case .playlist(let id) = macSelection, !ids.contains(id) { macSelection = .home }
            }
    }

    /// The sidebar's sections kept as they were left (their scroll, the pages opened in them) once
    /// visited, as tabs are; a playlist's page is made again each time.
    private static let keptSections: [MacSection] = [.search, .home, .library, .liked, .history, .downloads, .podcasts, .settings]

    private var macPages: some View {
        ZStack {
            ForEach(Self.keptSections.filter { visitedSections.contains($0) || $0 == macSelection }, id: \.self) { section in
                let shown = section == macSelection
                macPage(section)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
            if case .playlist(let id) = macSelection {
                NavigationStack { PlaylistDetailView(playlistID: id) }
                    .id(id)
            }
        }
        .onChange(of: macSelection, initial: true) { _, section in
            if Self.keptSections.contains(section) { visitedSections.insert(section) }
        }
    }

    @ViewBuilder private func macPage(_ section: MacSection) -> some View {
        switch section {
        case .search: SearchView()
        case .home: HomeView()
        case .library: LibraryView()
        case .liked: NavigationStack { TrackCollectionView(collection: .liked) }
        case .history: NavigationStack { TrackCollectionView(collection: .history) }
        case .downloads: NavigationStack { DownloadsView() }
        case .podcasts: NavigationStack { PodcastsView() }
        case .settings: SettingsView()
        case .playlist(let id): NavigationStack { PlaylistDetailView(playlistID: id) }
        }
    }
}

/// The Mac's sidebar, as Apple Music's on macOS 26: a panel of Liquid Glass floating inside the
/// window (or flat black in the classic style), the window's buttons at its top, the library's
/// parts and the playlists (with their covers) in sections that fold, and Settings at its foot.
private struct MacSidebar: View {
    /// Wider than the system's, for bigger names, symbols and covers, easier to see.
    static let width: CGFloat = 290
    static let inset: CGFloat = 10

    @Binding var selection: MacSection
    /// The window's title bar (its buttons), which the panel runs under.
    let top: CGFloat
    @EnvironmentObject private var library: Library
    @Environment(\.interfaceStyle) private var style
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @AppStorage("mac.sidebar.libraryOpen") private var libraryOpen = true
    @AppStorage("mac.sidebar.playlistsOpen") private var playlistsOpen = true

    private var classic: Bool { style == .classic }
    private var tint: Color { classic ? ClassicPalette.accent : accent.color }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    item("Home", symbol: classic ? "house.fill" : "house", section: .home)
                    item("Cerca", symbol: "magnifyingglass", section: .search)
                    header(classic ? "La tua libreria" : "Libreria", open: $libraryOpen)
                    if libraryOpen {
                        item(classic ? "La tua libreria" : "Libreria",
                             symbol: classic ? "books.vertical" : "square.stack", section: .library)
                        item(classic ? "Brani che ti piacciono" : "Preferiti",
                             symbol: classic ? "heart.fill" : "heart", section: .liked)
                        item("Cronologia", symbol: "clock", section: .history)
                        item("Download", symbol: "arrow.down.circle", section: .downloads)
                        item("Podcast", symbol: "mic", section: .podcasts)
                    }
                    if !library.playlists.isEmpty {
                        header("Playlist", open: $playlistsOpen)
                        if playlistsOpen {
                            ForEach(library.playlists) { playlist in
                                MacSidebarRow(selected: selection == .playlist(playlist.id),
                                              accent: tint, classic: classic) {
                                    selection = .playlist(playlist.id)
                                } icon: {
                                    PlaylistArtwork(playlist: playlist, size: classic ? 40 : 44,
                                                    cornerRadius: classic ? 4 : 8)
                                        .accessibilityHidden(true)
                                } title: {
                                    Text(verbatim: playlist.name)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            // Below the window's buttons, which sit on the glass: the list never scrolls under them.
            .padding(.top, max(top, 28) + 4)
            Divider()
                .overlay(classic ? Color.white.opacity(0.12) : Color.primary.opacity(0.2))
                .padding(.horizontal, 16)
            item("Impostazioni", symbol: "gearshape", section: .settings)
                .padding(10)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .foregroundStyle(classic ? Color.white : Color.primary)
        .modifier(MacSidebarChrome(classic: classic, accent: tint))
    }

    private func item(_ title: LocalizedStringKey, symbol: String, section: MacSection) -> some View {
        MacSidebarRow(selected: selection == section, accent: tint, classic: classic) {
            selection = section
        } icon: {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(classic ? (selection == section ? ClassicPalette.accent : Color.white)
                                 : accent.color)
        } title: {
            Text(title)
        }
    }

    /// A section's name, which folds it or opens it, as the system's sidebar does.
    private func header(_ title: LocalizedStringKey, open: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { open.wrappedValue.toggle() }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(open.wrappedValue ? 0 : -90))
                    .font(.caption.weight(.semibold))
            }
            .font(.headline)
            .foregroundStyle(classic ? ClassicPalette.secondaryText : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 18)
            .padding(.bottom, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Glass in Seaglass's style; flat near-black in the classic one.
private struct MacSidebarChrome: ViewModifier {
    let classic: Bool
    let accent: Color

    func body(content: Content) -> some View {
        if classic {
            content
                .background(ClassicPalette.surface, in: .rect(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                }
        } else {
            // Faintly in the theme's colour, so the glass reads as glass over the window's plain background.
            content.glassEffect(.regular.tint(accent.opacity(0.12)), in: .rect(cornerRadius: 24))
        }
    }
}

/// Glass capsule in Seaglass's style; flat elevated bar in the classic one.
private struct MacPlayerBarChrome: ViewModifier {
    let classic: Bool

    func body(content: Content) -> some View {
        if classic {
            content
                .background(ClassicPalette.elevated, in: .capsule)
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
        } else {
            content.glassEffect(.regular, in: .capsule)
        }
    }
}

/// A line of the Mac's sidebar: lit while its page is open, a lighter fill under the pointer.
private struct MacSidebarRow<Icon: View, Title: View>: View {
    let selected: Bool
    let accent: Color
    var classic = false
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.frame(width: classic ? 40 : 44, height: classic ? 40 : 44)
                title
                    .font(.title3)
                    .lineLimit(1)
                    .foregroundStyle(selected ? accent : (classic ? Color.white : Color.primary))
                    .fontWeight(selected ? .semibold : .regular)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minHeight: classic ? 48 : 52)
            .background {
                RoundedRectangle(cornerRadius: classic ? 8 : 14, style: .continuous)
                    .fill(fill)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: Color {
        if classic {
            return selected ? Color.white.opacity(0.12) : (hovering ? Color.white.opacity(0.06) : .clear)
        }
        return Color.primary.opacity(selected ? 0.1 : hovering ? 0.05 : 0)
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

/// The classic style on an iPhone and an iPad: Home, Cerca and La tua libreria in the style's own bar along
/// the bottom, the mini player above it, the settings behind the profile button (see `InterfaceStyle`).
private struct ClassicTabs: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var router: AppRouter
    @Binding var selection: AppTab

    var body: some View {
        let reserved = ClassicBottomBar.reserved(hasSong: player.current != nil)
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView().classicTabPage(reserving: reserved)
            }
            Tab("Cerca", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchView().classicTabPage(reserving: reserved)
            }
            Tab("La tua libreria", systemImage: "books.vertical.fill", value: AppTab.library) {
                LibraryView().classicTabPage(reserving: reserved)
            }
            Tab("Impostazioni", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView().classicTabPage(reserving: reserved)
            }
        }
        .overlay(alignment: .bottom) { ClassicBottomBar(selection: $selection) }
        .background(ClassicPalette.background.ignoresSafeArea())
        .onChange(of: router.pendingTab) { _, tab in
            guard let tab else { return }
            selection = tab
            router.pendingTab = nil
        }
    }
}
