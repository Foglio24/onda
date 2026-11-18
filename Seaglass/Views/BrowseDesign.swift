import SwiftUI
import UIKit

/// A stable colour field for browsing, independent of the artwork in Now Playing.
struct BrowseBackground: View {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    var body: some View {
        if style == .classic {
            AmbientBackground()
        } else {
            Color(uiColor: .systemBackground)
                .overlay(alignment: .top) {
                    if !reduceTransparency {
                        LinearGradient(
                            colors: [accent.color.opacity(scheme == .dark ? 0.23 : 0.13), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(height: 410)
                    }
                }
                .ignoresSafeArea()
        }
    }
}

/// A tinted card for browsing content. Glass highlights the controls on top.
struct BrowsePanel: ViewModifier {
    @Environment(\.interfaceStyle) private var style
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
            let shape = RoundedRectangle(cornerRadius: featured ? 28 : 22)
            content
                .padding(featured ? 22 : 16)
                .background {
                    shape.fill(Color(uiColor: .secondarySystemBackground))
                    if !reduceTransparency {
                        shape.fill(
                            LinearGradient(colors: [accent.color.opacity(featured ? 0.18 : 0.08), .clear],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    }
                }
                .overlay { shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1).allowsHitTesting(false) }
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
