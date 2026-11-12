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

/// The classic style's colours: black pages, slightly lighter cards, grey secondary text, green.
enum ClassicPalette {
    /// Pure black, as the common streaming apps' home and library.
    static let background = Color.black
    static let surface = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let elevated = Color(red: 0.18, green: 0.18, blue: 0.18)
    static let pill = Color(red: 0.20, green: 0.20, blue: 0.20)
    static let secondaryText = Color(red: 0.70, green: 0.70, blue: 0.70)
    static let accent = Color(red: 0.114, green: 0.725, blue: 0.329)
}

/// The style for every view below: in the environment, and dark throughout in the classic one.
struct InterfaceStyleModifier: ViewModifier {
    @AppStorage(Preferences.interfaceStyle) private var style: InterfaceStyle = .seaglass

    func body(content: Content) -> some View {
        content
            .environment(\.interfaceStyle, style)
            .preferredColorScheme(style == .classic ? .dark : nil)
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
            content.buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.white)
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
            // Nearly opaque behind the tabs (down to the screen's edge), so the page doesn't show through
            // their names; the fade is above them, behind the mini player.
            .background {
                Color.black.opacity(0.94)
                    .padding(.top, player.current != nil ? -8 : 0)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
        }
        .background {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85), .black], startPoint: .top, endPoint: .bottom)
                .padding(.top, player.current != nil ? 30 : -20)
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
            .foregroundStyle(on ? Color.white : ClassicPalette.secondaryText)
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

/// Classic profile menu: name, Recenti, Impostazioni. No friends activity and no messages —
/// Seaglass has neither (those stay out on purpose).
struct ClassicProfileSheet: View {
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var account = AccountService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    profileHeader
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
                }
                Section {
                    if account.isAvailable {
                        NavigationLink {
                            AccountSettingsView()
                        } label: {
                            Label("Profilo", systemImage: "person")
                        }
                    }
                    NavigationLink {
                        TrackCollectionView(collection: .history)
                    } label: {
                        Label("Recenti", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        dismiss()
                        // Settings has its own stack: open it as its own sheet after this one closes.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            router.showSettings = true
                        }
                    } label: {
                        Label("Impostazioni e privacy", systemImage: "gearshape")
                    }
                    .foregroundStyle(.primary)
                }
                .listRowBackground(ClassicPalette.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ClassicPalette.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .onDisappear {
            // Keep the flag in sync if the sheet is dismissed by a swipe.
            router.showProfileMenu = false
        }
    }

    private var profileHeader: some View {
        let letter = ProfileButton.letter(for: account)
        let name = account.details?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .center, spacing: 14) {
            Text(letter)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 64, height: 64)
                .background(ProfileButton.avatarTint(for: letter), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(name?.isEmpty == false ? name! : String(localized: "Seaglass"))
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                if account.isAvailable {
                    Text("Visualizza profilo")
                        .font(.subheadline)
                        .foregroundStyle(ClassicPalette.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
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
                .foregroundStyle(selected ? Color.black : Color.white)
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
                .foregroundStyle(.white)
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
                .fill(Color.white.opacity(0.35))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 52, cornerRadius: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
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
            Divider().overlay(Color.white.opacity(0.12))
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
        .preferredColorScheme(.dark)
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
                .foregroundStyle(.white)
                .frame(width: 28)
            Text(title)
                .font(.body)
                .foregroundStyle(.white)
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
}
