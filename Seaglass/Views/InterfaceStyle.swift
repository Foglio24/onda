import SwiftUI
import UIKit

/// How the whole app looks, chosen in Settings › Aspetto. Seaglass: Liquid Glass, the theme's colour and
/// the cover's colours behind every page. Classico: black and flat, in green, laid out as the most common
/// streaming apps are (the tabs Home, Cerca and La tua libreria along the bottom, the mini player in the
/// cover's colour above them, the profile button for the settings at the top). The same app, features and
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

/// The classic style's colours: near-black pages, slightly lighter cards, grey secondary text, green.
enum ClassicPalette {
    static let background = Color(red: 0.071, green: 0.071, blue: 0.071)
    static let surface = Color(red: 0.118, green: 0.118, blue: 0.118)
    static let elevated = Color(red: 0.165, green: 0.165, blue: 0.165)
    static let secondaryText = Color(red: 0.70, green: 0.70, blue: 0.70)
    static let accent = Color(red: 0.11, green: 0.80, blue: 0.37)
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

/// The classic style's way to the settings: a round profile button at the top of the main pages.
struct ProfileButton: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        Button { router.showSettings = true } label: {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(ClassicPalette.accent)
        }
        .accessibilityLabel(Text("Impostazioni"))
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
