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
    @AppStorage(Preferences.macClassicSidebarWidth) private var classicSidebarWidth: Double = 280
    @AppStorage(Preferences.macClassicQueueWidth) private var classicQueueWidth: Double = 320
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
        .sheet(item: $router.profilePage) { page in
            NavigationStack {
                Group {
                    switch page {
                    case .account: AccountSettingsView()
                    case .recents: TrackCollectionView(collection: .history)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fine") { router.profilePage = nil }
                    }
                }
            }
            .appEnvironment()
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
    /// under it. The classic style has its own (see `classicMacLayout`). The sidebar is the app's
    /// own: the system's (TabView, NavigationSplitView) is opaque in an iPad app on a Mac.
    @ViewBuilder private var macTabs: some View {
        if style == .classic { classicMacLayout } else { seaglassMacLayout }
    }

    /// The classic style on a Mac, as the common streaming apps' desktop: three resizable panels
    /// (library | page | queue) on a black window, and the player bar along the whole bottom.
    private var classicMacLayout: some View {
        GeometryReader { proxy in
            let top = max(proxy.safeAreaInsets.top, 28) + 6
            let available = max(proxy.size.width - 16, 600)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    MacClassicSidebar(selection: $macSelection, width: classicSidebarWidth)
                    ClassicMacResizeHandle(width: $classicSidebarWidth,
                                          minWidth: 220, maxWidth: min(420, available * 0.4))
                    macPages
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ClassicPalette.panel)
                        .clipShape(.rect(cornerRadius: 8))
                    if router.showMacQueuePanel {
                        ClassicMacResizeHandle(width: $classicQueueWidth,
                                              minWidth: 240, maxWidth: min(480, available * 0.45),
                                              expandsLeading: false)
                        MacClassicQueuePanel(width: classicQueueWidth) {
                            router.setMacQueuePanel(false)
                        }
                    }
                }
                .padding(.top, top)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                MacPlayerBar()
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        router.miniPlayerFrame = frame
                    }
            }
            .background(ClassicPalette.window)
            .ignoresSafeArea(edges: .top)
            .onAppear {
                // Clamp widths if the window is narrower than when they were last saved.
                classicSidebarWidth = min(max(classicSidebarWidth, 220), min(420, available * 0.4))
                classicQueueWidth = min(max(classicQueueWidth, 240), min(480, available * 0.45))
            }
        }
        // A deleted playlist's page goes with it.
        .onChange(of: library.playlists.map(\.id)) { _, ids in
            if case .playlist(let id) = macSelection, !ids.contains(id) { macSelection = .home }
        }
    }

    private var seaglassMacLayout: some View {
        macPages
            .safeAreaPadding(.bottom, MacPlayerBar.height + 24)
            .padding(.leading, MacSidebar.width + 2 * MacSidebar.inset)
            .background {
                Color(.systemBackground).ignoresSafeArea()
            }
            .overlay(alignment: .bottom) {
                MacPlayerBar()
                    .glassEffect(.regular, in: .capsule)
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

/// Drag handle between classic Mac panels. Dragging changes `width` (the panel on the leading
/// side when `expandsLeading` is true; the trailing panel otherwise).
private struct ClassicMacResizeHandle: View {
    @Binding var width: Double
    let minWidth: CGFloat
    let maxWidth: CGFloat
    var expandsLeading: Bool = true
    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(.rect)
            .overlay(alignment: .center) {
                Capsule()
                    .fill(ClassicPalette.separator)
                    .frame(width: 2, height: 28)
                    .opacity(0.6)
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = width }
                        let delta = expandsLeading ? value.translation.width : -value.translation.width
                        let next = (dragStart ?? width) + delta
                        width = min(max(next, minWidth), maxWidth)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityLabel(Text("Ridimensiona pannello"))
            .accessibilityAddTraits(.isButton)
    }
}

/// The classic Mac right panel: queue and now-playing, as the common streaming apps' desktop.
private struct MacClassicQueuePanel: View {
    let width: Double
    let onClose: () -> Void
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Coda")
                    .font(.title3.bold())
                    .foregroundStyle(ClassicPalette.primaryText)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ClassicPalette.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Chiudi"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if let track = player.current {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stai ascoltando")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ClassicPalette.secondaryText)
                    HStack(spacing: 10) {
                        ArtworkView(track: track, size: 48, cornerRadius: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ClassicPalette.accent)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(ClassicPalette.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            Group {
                if player.shuffleEnabled {
                    Text("Riproduzione casuale da:")
                } else {
                    Text("Prossima traccia da: \(player.source)")
                }
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(ClassicPalette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            QueueView(macSidePanel: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(ClassicPalette.panel, in: .rect(cornerRadius: 8))
        .foregroundStyle(ClassicPalette.primaryText)
    }
}

/// The classic style's sidebar on a Mac, as the common streaming apps' desktop: two dark panels
/// on the black window. The first has Home, Cerca and Impostazioni;
/// the second is the library: Brani che ti piacciono, Cronologia, Download and Podcast as square
/// tiles, then the playlists with their covers, each with what it is under its name.
private struct MacClassicSidebar: View {
    @Binding var selection: MacSection
    var width: Double = 280
    @EnvironmentObject private var library: Library
    @ObservedObject private var podcasts = PodcastLibrary.shared
    @State private var libraryFilter: LibraryFilter = .all

    private enum LibraryFilter: Hashable {
        case all, playlists, podcasts
    }

    private func libraryFilterPill(_ title: LocalizedStringKey, filter: LibraryFilter) -> some View {
        let on = libraryFilter == filter
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                libraryFilter = on ? .all : filter
            }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(on ? Color.black : ClassicPalette.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(on ? ClassicPalette.accent : ClassicPalette.elevated, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                navItem("Home", symbol: "house", selected: "house.fill", section: .home)
                navItem("Cerca", symbol: "magnifyingglass", selected: "magnifyingglass", section: .search)
                navItem("Impostazioni", symbol: "gearshape", selected: "gearshape.fill", section: .settings)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClassicPalette.panel, in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 0) {
                Button { selection = .library } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selection == .library ? "books.vertical.fill" : "books.vertical")
                            .font(.title2)
                        Text("La tua libreria")
                            .font(.headline.weight(.bold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selection == .library ? ClassicPalette.primaryText : ClassicPalette.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                HStack(spacing: 8) {
                    libraryFilterPill("Playlist", filter: .playlists)
                    libraryFilterPill("Podcast", filter: .podcasts)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if libraryFilter == .all || libraryFilter == .playlists {
                            libraryRow("Brani che ti piacciono", subtitle: String(localized: "\(library.liked.count) brani"),
                                       section: .liked) {
                                tile("heart.fill", colors: [Color(red: 0.27, green: 0.18, blue: 0.85), Color(red: 0.55, green: 0.75, blue: 0.95)])
                            }
                        }
                        if libraryFilter == .all {
                            libraryRow("Cronologia", subtitle: String(localized: "\(library.history.count) brani"),
                                       section: .history) {
                                tile("clock.fill", colors: [.orange, Color(red: 0.75, green: 0.35, blue: 0.1)])
                            }
                            libraryRow("Download", subtitle: String(localized: "\(library.downloads.count) brani"),
                                       section: .downloads) {
                                tile("arrow.down", colors: [Color(red: 0.1, green: 0.55, blue: 0.95), Color(red: 0.05, green: 0.3, blue: 0.6)])
                            }
                        }
                        if libraryFilter == .all || libraryFilter == .podcasts {
                            libraryRow("Podcast", subtitle: String(localized: "\(podcasts.followed.count) seguiti"),
                                       section: .podcasts) {
                                tile("mic.fill", colors: [Color(red: 0.6, green: 0.3, blue: 0.9), Color(red: 0.35, green: 0.12, blue: 0.55)])
                            }
                        }
                        if libraryFilter == .all || libraryFilter == .playlists {
                            ForEach(library.playlists) { playlist in
                                libraryRow(LocalizedStringKey(playlist.name), verbatim: playlist.name,
                                           subtitle: playlist.countLabel, section: .playlist(playlist.id)) {
                                    PlaylistArtwork(playlist: playlist, size: 48, cornerRadius: 4)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ClassicPalette.panel, in: .rect(cornerRadius: 8))
        }
        .frame(width: width)
        .foregroundStyle(ClassicPalette.primaryText)
    }

    /// Home, Cerca, Impostazioni: white and filled when open, grey otherwise.
    private func navItem(_ title: LocalizedStringKey, symbol: String, selected: String, section: MacSection) -> some View {
        let on = selection == section
        return Button { selection = section } label: {
            HStack(spacing: 16) {
                Image(systemName: on ? selected : symbol)
                    .font(.title2.weight(on ? .semibold : .regular))
                    .frame(width: 28)
                Text(title)
                    .font(.headline.weight(.bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? ClassicPalette.primaryText : ClassicPalette.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// A line of the library: its cover or tile, its name (green while open) and what it is.
    private func libraryRow<Artwork: View>(_ title: LocalizedStringKey, verbatim: String? = nil, subtitle: String,
                                           section: MacSection, @ViewBuilder artwork: () -> Artwork) -> some View {
        MacClassicLibraryRow(selected: selection == section, title: title, verbatim: verbatim, subtitle: subtitle,
                             artwork: artwork()) {
            selection = section
        }
    }

    /// A library part's square tile: its symbol on a gradient, as large as a playlist's cover.
    private func tile(_ symbol: String, colors: [Color]) -> some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 4))
    }
}

/// A line of the classic library on a Mac: a lighter fill while open or under the pointer.
private struct MacClassicLibraryRow<Artwork: View>: View {
    let selected: Bool
    let title: LocalizedStringKey
    var verbatim: String?
    let subtitle: String
    let artwork: Artwork
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if let verbatim { Text(verbatim: verbatim) } else { Text(title) }
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(selected ? ClassicPalette.accent : ClassicPalette.primaryText)
                    .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(ClassicPalette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ClassicPalette.primaryText.opacity(selected ? 0.1 : (hovering ? 0.06 : 0)))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The Mac's sidebar, as Apple Music's on macOS 26: a panel of Liquid Glass floating inside the
/// window (the classic style has `MacClassicSidebar`), the window's buttons at its top, the library's
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
                .overlay(classic ? ClassicPalette.separator : Color.primary.opacity(0.2))
                .padding(.horizontal, 16)
            item("Impostazioni", symbol: "gearshape", section: .settings)
                .padding(10)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .foregroundStyle(classic ? ClassicPalette.primaryText : Color.primary)
        .modifier(MacSidebarChrome(classic: classic, accent: tint))
    }

    private func item(_ title: LocalizedStringKey, symbol: String, section: MacSection) -> some View {
        MacSidebarRow(selected: selection == section, accent: tint, classic: classic) {
            selection = section
        } icon: {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(classic ? (selection == section ? ClassicPalette.accent : ClassicPalette.primaryText)
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

/// Glass in Seaglass's style; flat in the classic one (dark grey, or light grey in the light mode).
private struct MacSidebarChrome: ViewModifier {
    let classic: Bool
    let accent: Color

    func body(content: Content) -> some View {
        if classic {
            content
                .background(ClassicPalette.surface, in: .rect(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(ClassicPalette.separator.opacity(0.5), lineWidth: 1)
                }
        } else {
            // Faintly in the theme's colour, so the glass reads as glass over the window's plain background.
            content.glassEffect(.regular.tint(accent.opacity(0.12)), in: .rect(cornerRadius: 24))
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
                    .foregroundStyle(selected ? accent : (classic ? ClassicPalette.primaryText : Color.primary))
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
            return selected ? ClassicPalette.primaryText.opacity(0.12) : (hovering ? ClassicPalette.primaryText.opacity(0.06) : .clear)
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
        // Over the tabs and the mini player too, as the common streaming apps' profile menu.
        .overlay { ClassicProfileDrawer() }
        .background(ClassicPalette.background.ignoresSafeArea())
        .onChange(of: router.pendingTab) { _, tab in
            guard let tab else { return }
            selection = tab
            router.pendingTab = nil
        }
    }
}
