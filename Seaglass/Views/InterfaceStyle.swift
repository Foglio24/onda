import SwiftUI
import UIKit

/// How the whole app looks, chosen in Settings › Aspetto. Seaglass: Liquid Glass, the theme's colour and
/// the cover's colours behind every page. Classico: black and flat, in green, laid out as the most common
/// streaming apps are (on the phone: Home, Cerca and La tua libreria along the bottom with the mini player
/// above them; on the Mac: the same look for the sidebar and the player bar). The same app, features and
/// pages in both; only how they look changes.
enum InterfaceStyle: String, CaseIterable, Identifiable {
    case seaglass, classic

    var id: Self { self }

    var title: String {
        switch self {
        case .seaglass: return String(localized: "Seaglass")
        case .classic: return String(localized: "Classico")
        }
    }

    /// A cover's corner radius: as asked in Seaglass's style; nearly square (6 points at most) in the
    /// classic one, as covers are in the common streaming apps.
    func coverRadius(_ radius: CGFloat) -> CGFloat {
        self == .classic ? min(radius, 6) : radius
    }

    /// The style chosen, read where no view's environment is at hand (a colour worked out in a model).
    static var current: InterfaceStyle {
        UserDefaults.standard.string(forKey: Preferences.interfaceStyle).flatMap(InterfaceStyle.init(rawValue:)) ?? .seaglass
    }
}

extension EnvironmentValues {
    @Entry var interfaceStyle: InterfaceStyle = .seaglass
}

/// Light or dark, for the whole app: as the device (the default), or always one of the two. The
/// player keeps its own dark look on the cover's colours in both, as the common streaming apps.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case automatic, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Automatica")
        case .light: return String(localized: "Chiara")
        case .dark: return String(localized: "Scura")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The classic style's colours, for the dark mode and the light one: black (or white) pages,
/// cards a little lighter (or darker), grey secondary text, green.
enum ClassicPalette {
    static let background = adaptive(dark: .black, light: .white)
    static let surface = adaptive(dark: gray(0.12), light: gray(0.96))
    static let elevated = adaptive(dark: gray(0.18), light: gray(0.92))
    static let pill = adaptive(dark: gray(0.20), light: gray(0.90))
    /// The text on the pages: white in the dark, black in the light.
    static let primaryText = adaptive(dark: .white, light: .black)
    /// The same for UIKit's views (the output button).
    static let uiPrimaryText = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
    static let secondaryText = adaptive(dark: gray(0.70), light: gray(0.40))
    /// The Mac's window behind the panels (sidebar, page), as the common streaming apps' desktop:
    /// black, a little darker than the panels; light grey in the light mode.
    static let window = adaptive(dark: .black, light: gray(0.90))
    /// The Mac's panels on that window: the sidebar's and the page's.
    static let panel = adaptive(dark: gray(0.071), light: .white)
    /// The search field: white on the dark pages, light grey on the light ones (its text is black in both).
    static let field = adaptive(dark: .white, light: gray(0.92))
    /// Lines between rows.
    static let separator = adaptive(dark: UIColor(white: 1, alpha: 0.12), light: UIColor(white: 0, alpha: 0.10))
    static let accent = Color(red: 0.114, green: 0.725, blue: 0.329)

    private static func gray(_ white: CGFloat) -> UIColor { UIColor(white: white, alpha: 1) }

    private static func adaptive(dark: UIColor, light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// The style for every view below, in the environment, and the light or dark mode chosen.
struct InterfaceStyleModifier: ViewModifier {
    @AppStorage(Preferences.interfaceStyle) private var style: InterfaceStyle = .seaglass
    @AppStorage(Preferences.appearanceMode) private var mode: AppearanceMode = .automatic

    func body(content: Content) -> some View {
        content
            .environment(\.interfaceStyle, style)
            .preferredColorScheme(mode.colorScheme)
    }
}

extension View {
    /// Liquid Glass in Seaglass's style (tinted, when a tint is given); in the classic one, a flat surface
    /// a little lighter than the page, or the tint itself.
    func styledSurface<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(StyledSurface(shape: shape, interactive: interactive, tint: tint))
    }
}

extension View {
    /// A Liquid Glass button in Seaglass's style; in the classic one, a flat capsule (grey, or in the
    /// theme's green when prominent).
    func styledButton(prominent: Bool = false) -> some View {
        modifier(StyledButton(prominent: prominent))
    }
}

private struct StyledButton: ViewModifier {
    @Environment(\.interfaceStyle) private var style
    let prominent: Bool

    func body(content: Content) -> some View {
        switch (style, prominent) {
        case (.classic, true):
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        case (.classic, false):
            content.buttonStyle(.bordered).buttonBorderShape(.capsule).tint(ClassicPalette.primaryText)
        case (.seaglass, true):
            content.buttonStyle(.glassProminent)
        case (.seaglass, false):
            content.buttonStyle(.glass)
        }
    }
}

private struct StyledSurface<S: Shape>: ViewModifier {
    @Environment(\.interfaceStyle) private var style
    let shape: S
    let interactive: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        if style == .classic {
            content.background(tint ?? ClassicPalette.elevated, in: shape)
        } else {
            let glass: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            content.glassEffect(interactive ? glass.interactive() : glass, in: shape)
        }
    }
}

// MARK: The classic style's bottom bar

/// The tabs of the classic style, along the bottom with the mini player above them, over a fade to black.
struct ClassicBottomBar: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var router: AppRouter
    @Binding var selection: AppTab

    /// The space the pages leave at their bottom for the bar (and the mini player, when a song is there).
    static func reserved(hasSong: Bool) -> CGFloat { hasSong ? 122 : 58 }

    var body: some View {
        VStack(spacing: 6) {
            if player.current != nil {
                ClassicMiniPlayer { router.openPlayer() }
                    .padding(.horizontal, 8)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        router.miniPlayerFrame = frame
                    }
            }
            HStack(spacing: 0) {
                item(.home, title: "Home", symbol: "house", selected: "house.fill")
                item(.search, title: "Cerca", symbol: "magnifyingglass", selected: "magnifyingglass")
                item(.library, title: "La tua libreria", symbol: "books.vertical", selected: "books.vertical.fill")
            }
            .padding(.top, 2)
        }
        // As the common streaming apps' bar: a fade from clear above the mini player to nearly
        // opaque at the screen's edge, so the page shows through it, dimmer towards the bottom.
        .background {
            LinearGradient(stops: [
                .init(color: ClassicPalette.background.opacity(0), location: 0),
                .init(color: ClassicPalette.background.opacity(0.72), location: 0.42),
                .init(color: ClassicPalette.background.opacity(0.9), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .padding(.top, player.current != nil ? 0 : -28)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }

    private func item(_ tab: AppTab, title: LocalizedStringKey, symbol: String, selected: String) -> some View {
        let on = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: on ? selected : symbol)
                    .font(.system(size: 22, weight: on ? .semibold : .regular))
                    .frame(height: 26)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(on ? ClassicPalette.primaryText : ClassicPalette.secondaryText)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The classic style's mini player: in the cover's colour, the song and its artist, the output and play,
/// and a thin line for where the song is.
struct ClassicMiniPlayer: View {
    @EnvironmentObject private var player: PlayerController
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(track: player.current, size: 40, cornerRadius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.current?.title ?? "")
                    .font(.footnote.weight(.bold))
                    .lineLimit(1)
                Text(player.errorMessage ?? player.current?.artist ?? "")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            AirPlayButton(activeTint: ClassicPalette.accent)
                .frame(width: 34, height: 34)
            Button { player.togglePlayPause() } label: {
                Group {
                    if player.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(player.artworkColor.mix(with: .black, by: 0.5), in: .rect(cornerRadius: 8))
        .overlay(alignment: .bottom) { ClassicMiniProgress().padding(.horizontal, 8) }
        .contentShape(.rect)
        .onTapGesture { onOpen() }
        .animation(.easeInOut(duration: 0.6), value: player.artworkColor)
    }
}

/// Where the song is, as a thin line along the mini player's bottom edge (its own view: it changes often).
private struct ClassicMiniProgress: View {
    @EnvironmentObject private var progress: PlaybackProgress

    var body: some View {
        GeometryReader { geometry in
            let share = progress.duration > 0 ? min(1, max(0, progress.currentTime / progress.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white).frame(width: geometry.size.width * share)
            }
            // Gliding between the player's four ticks a second, at the screen's rate.
            .animation(.linear(duration: 0.25), value: share)
        }
        .frame(height: 2)
    }
}

/// The classic style's way to the profile menu: a round letter at the top of the main pages.
struct ProfileButton: View {
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var account = AccountService.shared

    var body: some View {
        Button { router.showProfileMenu = true } label: {
            Text(Self.letter(for: account))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 32, height: 32)
                .background(Self.avatarTint(for: Self.letter(for: account)), in: .circle)
        }
        .accessibilityLabel(Text("Profilo"))
    }

    /// First letter of the signed-in name, or "S" when there is none.
    static func letter(for account: AccountService) -> String {
        let name = account.details?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let first = name.first { return String(first).uppercased() }
        return "S"
    }

    static func avatarTint(for letter: String) -> Color {
        // Stable colour from the letter, so it doesn't jump between launches.
        let hues: [Color] = [
            Color(red: 0.91, green: 0.40, blue: 0.55),
            Color(red: 0.35, green: 0.65, blue: 0.95),
            Color(red: 0.95, green: 0.55, blue: 0.25),
            Color(red: 0.55, green: 0.45, blue: 0.95),
            Color(red: 0.30, green: 0.75, blue: 0.55),
            Color(red: 0.90, green: 0.35, blue: 0.35),
        ]
        let index = abs(letter.unicodeScalars.first.map { Int($0.value) } ?? 0) % hues.count
        return hues[index]
    }
}

/// The top of the classic style's main pages, as the common streaming apps: the profile on the left,
/// the page's title (or its filters) beside it, the page's buttons on the right. A row of its own,
/// pinned over the page, rather than the system's toolbar, which wrapped the profile in a wider glass
/// capsule and cut the title off.
struct ClassicHeader<Middle: View, Trailing: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var middle: Middle
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            // The profile menu slides in over the iPhone's and iPad's tabs; a Mac has its sidebar.
            if !ProcessInfo.processInfo.isMacCatalystApp { ProfileButton() }
            if let title {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(ClassicPalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            middle
            Spacer(minLength: 0)
            HStack(spacing: 18) { trailing }
                .font(.title3.weight(.semibold))
                .foregroundStyle(ClassicPalette.primaryText)
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
        }
        .frame(height: 48)
        .padding(.horizontal, 16)
        .background { AmbientBackground() }
    }
}

extension ClassicHeader where Middle == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, middle: { EmptyView() }, trailing: trailing)
    }
}

extension View {
    /// A classic main page: its own header pinned at the top instead of the navigation bar (pages
    /// pushed from it keep theirs, with the back button).
    func classicHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        let header = header()
        return toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { header }
    }
}

/// What the classic profile menu opens in a sheet of its own.
enum ProfilePage: String, Identifiable {
    case account, recents
    var id: Self { self }
}

/// The classic profile menu, as the common streaming apps': a panel that slides in from the left
/// over the page (which dims), with the profile at the top and the menu's rows under it. A tap on
/// the dimmed page or a swipe to the left closes it. No friends' activity or messages: Seaglass has
/// neither.
struct ClassicProfileDrawer: View {
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var account = AccountService.shared

    var body: some View {
        ZStack(alignment: .leading) {
            if router.showProfileMenu {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
                    .accessibilityHidden(true)
                panel
                    .containerRelativeFrame(.horizontal) { width, _ in min(340, width * 0.84) }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(ClassicPalette.surface.ignoresSafeArea())
                    .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                        if value.translation.width < -60 { close() }
                    })
                    .transition(.move(edge: .leading))
                    .accessibilityAddTraits(.isModal)
            }
        }
        .animation(.snappy(duration: 0.3), value: router.showProfileMenu)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open(account.isAvailable ? .account : nil) } label: {
                profileHeader
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 18)
            Rectangle()
                .fill(ClassicPalette.separator)
                .frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                row("Recenti", symbol: "clock.arrow.circlepath") { open(.recents) }
                row("Impostazioni e privacy", symbol: "gearshape") {
                    close()
                    router.showSettings = true
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(ClassicPalette.primaryText)
    }

    private var profileHeader: some View {
        let letter = ProfileButton.letter(for: account)
        let name = account.details?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HStack(spacing: 14) {
            Text(letter)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 52, height: 52)
                .background(ProfileButton.avatarTint(for: letter), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(name.isEmpty ? String(localized: "Seaglass") : name)
                    .font(.title3.bold())
                    .lineLimit(1)
                if account.isAvailable {
                    Text("Visualizza profilo")
                        .font(.subheadline)
                        .foregroundStyle(ClassicPalette.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    private func row(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 28)
                Text(title)
                    .font(.body.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func close() {
        router.showProfileMenu = false
    }

    private func open(_ page: ProfilePage?) {
        close()
        guard let page else { return }
        router.profilePage = page
    }
}

/// A filter chip of the classic style (Home, Libreria): green when on, dark grey when off.
struct ClassicPill: View {
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.black : ClassicPalette.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? ClassicPalette.accent : ClassicPalette.pill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A horizontal row of classic filter pills.
struct ClassicPillBar<Item: Hashable>: View {
    let items: [(Item, LocalizedStringKey)]
    @Binding var selection: Item?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { item, title in
                    ClassicPill(title: title, selected: selection == item) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selection = selection == item ? nil : item
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }
}

/// Section title of the classic Home: bold on the left, optional "Mostra tutto" on the right.
struct ClassicSectionHeader: View {
    let title: LocalizedStringKey
    var showAll: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(ClassicPalette.primaryText)
            Spacer(minLength: 8)
            if let showAll {
                Button(action: showAll) {
                    Text("Mostra tutto")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ClassicPalette.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// The classic style's song actions as a bottom sheet (cover, name, list of actions), not a system menu.
struct TrackActionSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    private var player: PlayerController { .shared }
    private var router: AppRouter { .shared }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(ClassicPalette.secondaryText.opacity(0.5))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 52, cornerRadius: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ClassicPalette.primaryText)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(ClassicPalette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            Divider().overlay(ClassicPalette.separator)
            ScrollView {
                VStack(spacing: 0) {
                    if let url = track.shareURL {
                        ShareLink(item: url) {
                            sheetRow("Condividi", symbol: "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)
                    }
                    sheetButton("Aggiungi a playlist…", symbol: "plus.circle") {
                        dismiss(); router.trackToAdd = track
                    }
                    sheetButton(library.isLiked(track) ? "Togli dai preferiti" : "Aggiungi ai preferiti",
                                symbol: library.isLiked(track) ? "heart.slash" : "heart") {
                        library.toggleLike(track); dismiss()
                    }
                    sheetButton("Aggiungi in coda", symbol: "text.line.last.and.arrowtriangle.forward") {
                        player.addToQueue(track); dismiss()
                    }
                    sheetButton("Riproduci dopo", symbol: "text.line.first.and.arrowtriangle.forward") {
                        player.playNext(track); dismiss()
                    }
                    if !track.isLocal {
                        sheetButton("Avvia radio", symbol: "dot.radiowaves.left.and.right") {
                            dismiss(); player.playRadio(from: track)
                        }
                    }
                    if !track.primaryArtist.isEmpty {
                        sheetButton("Vai all'artista", symbol: "music.mic") {
                            dismiss(); router.page = .artist(id: track.artistID, name: track.primaryArtist)
                        }
                    }
                    if let albumID = track.albumID {
                        sheetButton("Vai all'album", symbol: "square.stack") {
                            dismiss(); router.page = .album(id: albumID)
                        }
                    }
                    if !track.isLocal {
                        sheetButton("Informazioni sul brano", symbol: "info.circle") {
                            dismiss(); router.page = .song(track)
                        }
                        if downloads.isDownloaded(track) {
                            sheetButton("Rimuovi download", symbol: "trash") {
                                downloads.remove(track); dismiss()
                            }
                        } else if downloads.isQueued(track) {
                            sheetButton("Annulla download", symbol: "xmark.circle") {
                                downloads.cancel([track]); dismiss()
                            }
                        } else {
                            sheetButton("Scarica", symbol: "arrow.down.circle") {
                                downloads.download(track); dismiss()
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ClassicPalette.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(ClassicPalette.surface)
        .classicPageSheet()
    }

    private func sheetButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            sheetRow(title, symbol: symbol)
        }
        .buttonStyle(.plain)
    }

    private func sheetRow(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(ClassicPalette.primaryText)
                .frame(width: 28)
            Text(title)
                .font(.body)
                .foregroundStyle(ClassicPalette.primaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(.rect)
    }
}

extension View {
    /// A page of the classic style's tabs: the system's tab bar hidden (the style has its own), and room
    /// left at the bottom for it.
    func classicTabPage(reserving height: CGFloat) -> some View {
        toolbar(.hidden, for: .tabBar)
            .safeAreaPadding(.bottom, height)
    }
}

/// A list in the classic style: plain, edge to edge on the page's black. Its rows lose the system's
/// backgrounds and separators with `classicRows`. Unchanged in Seaglass's style.
struct ClassicList: ViewModifier {
    let classic: Bool

    func body(content: Content) -> some View {
        if classic {
            content.listStyle(.plain)
        } else {
            content
        }
    }
}

extension View {
    /// The rows of a section or a `ForEach` in the classic style's lists: on the page, without separators.
    func classicRows(_ classic: Bool) -> some View {
        listRowBackground(classic ? Color.clear : nil)
            .listRowSeparator(classic ? .hidden : .automatic)
            .listSectionSeparator(classic ? .hidden : .automatic)
    }

    /// Full-width sheet on iPad / Mac Catalyst (form sheets otherwise sit off-centre with a gap).
    /// An iPhone already fills the screen; enabling this there is harmless.
    @ViewBuilder func classicPageSheet(_ enabled: Bool = true) -> some View {
        if enabled { presentationSizing(.page) } else { self }
    }
}
