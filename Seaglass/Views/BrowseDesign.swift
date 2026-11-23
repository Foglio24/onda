import SwiftUI
import UIKit

/// A stable colour field for browsing, independent of the artwork in Now Playing: the theme's colour
/// washed down from the top of the screen and fading out by its bottom, over the whole height.
///
/// It only changes from top to bottom, never sideways, and always over the whole screen: the same
/// wash, drawn by every page and (on a Mac) by the window behind the sidebar, then lines up wherever
/// they meet. The first version faded diagonally inside a band 410 points high, which ended in a
/// straight edge across the screen (mid-page on an iPhone, under the sidebar's top on a Mac), and
/// pages that drew another background (the account, the equaliser) changed colour as they opened.
struct BrowseBackground: View {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    var body: some View {
        if style == .classic {
            AmbientBackground()
        } else {
            SeaglassBackdrop(tint: accent.color, dark: scheme == .dark, plain: reduceTransparency)
        }
    }
}

/// See `BrowseBackground`.
struct SeaglassBackdrop: View {
    let tint: Color
    let dark: Bool
    var plain = false

    var body: some View {
        let strength = dark ? 0.30 : 0.16
        Color(uiColor: .systemBackground)
            .overlay {
                if !plain {
                    LinearGradient(stops: [
                        .init(color: tint.opacity(strength), location: 0),
                        .init(color: tint.opacity(strength * 0.55), location: 0.22),
                        .init(color: tint.opacity(strength * 0.2), location: 0.5),
                        .init(color: tint.opacity(strength * 0.06), location: 0.78),
                        .init(color: tint.opacity(0), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.45), value: tint)
            .allowsHitTesting(false)
    }
}

/// A tinted card for browsing content. Glass highlights the controls on top.
struct BrowsePanel: ViewModifier {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    let featured: Bool

    init(featured: Bool = false) {
        self.featured = featured
    }

    @ViewBuilder func body(content: Content) -> some View {
        if style == .classic {
            content
        } else {
            let shape = RoundedRectangle(cornerRadius: featured ? 28 : 22, style: .continuous)
            content
                .padding(featured ? 22 : 16)
                .background {
                    shape.fill(Color(uiColor: .secondarySystemBackground).opacity(scheme == .dark ? 0.82 : 0.9))
                    if !reduceTransparency {
                        shape.fill(
                            LinearGradient(colors: [accent.color.opacity(featured ? 0.2 : 0.09), accent.color.opacity(0)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    }
                }
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.12 : 0.07), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                // A little depth in the light mode, where the panel is close to the page's white.
                .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 14, y: 5)
        }
    }
}

struct BrowseHeading: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.title2.weight(.bold))
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Motion

/// What a card, a tile or a cover does under a finger: it sinks a little and comes back with a spring.
/// Only in Seaglass's style (the classic one stays as it is), and not with Reduce Motion, where it only
/// dims. Glass that is already interactive has its own response and doesn't need this.
struct BrowsePressStyle: ButtonStyle {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && style != .classic
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? 0.965 : 1)
            .opacity(pressed ? 0.88 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BrowsePressStyle {
    static var browsePress: BrowsePressStyle { BrowsePressStyle() }
}

/// A page's sections come in one after the other the first time it shows: from a little lower, out
/// of transparent, `order` steps after the first. Nothing moves with Reduce Motion, or in the classic
/// style, and a section shown again (back from a page) isn't animated again.
struct BrowseAppear: ViewModifier {
    let order: Int
    @State private var shown = false
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let still = shown || reduceMotion || style == .classic
        content
            .opacity(still ? 1 : 0)
            .offset(y: still ? 0 : 16)
            .onAppear {
                guard !shown else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.86).delay(Double(min(order, 8)) * 0.05)) {
                    shown = true
                }
            }
    }
}

extension View {
    /// See `BrowseAppear`.
    func browseAppear(_ order: Int) -> some View { modifier(BrowseAppear(order: order)) }
}
