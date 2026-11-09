import SwiftUI

// The Home's pieces on a Mac, laid out as Apple Music's (see `HomeView.macSections`).

/// A row of cards that scrolls sideways, as Apple Music's on a Mac: while the pointer is over it,
/// arrows at its ends move it a page at a time (a mouse can't scroll sideways), and it stops on a card.
struct MacShelf<Card: View>: View {
    let title: LocalizedStringKey
    let count: Int
    let itemWidth: CGFloat
    let margin: CGFloat
    var spacing: CGFloat = 18
    @ViewBuilder let card: (Int) -> Card

    @State private var first: Int? = 0
    @State private var width: CGFloat = 0
    @State private var hovering = false

    /// How many cards fit across.
    private var perPage: Int {
        max(1, Int((width - 2 * margin + spacing) / (itemWidth + spacing)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .padding(.horizontal, margin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<count, id: \.self) { position in
                        card(position)
                            .frame(width: itemWidth, alignment: .leading)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .scrollPosition(id: $first, anchor: .leading)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay {
                if hovering { arrows }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }

    private var arrows: some View {
        HStack {
            if (first ?? 0) > 0 {
                arrow("chevron.left", label: Text("Pagina precedente")) { page(-1) }
            }
            Spacer()
            if (first ?? 0) + perPage < count {
                arrow("chevron.right", label: Text("Pagina successiva")) { page(1) }
            }
        }
        .padding(.horizontal, 6)
        .transition(.opacity)
    }

    private func arrow(_ symbol: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline.weight(.semibold))
                .frame(width: 34, height: 34)
                .contentShape(.circle)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func page(_ direction: Int) {
        let target = min(max(0, (first ?? 0) + direction * perPage), max(0, count - perPage))
        withAnimation(.smooth) { first = target }
    }
}

/// A big card for a mix, as Apple Music's Top Picks: a caption above, the cover, and under it the
/// title on a band coloured by the cover itself.
struct MacPickCard<Artwork: View>: View {
    let caption: String
    let title: String
    var busy = false
    @ViewBuilder let artwork: Artwork
    @State private var hovering = false

    private let width: CGFloat = 230
    private let band: CGFloat = 68

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            VStack(spacing: 0) {
                artwork
                    .frame(width: width, height: width)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        if busy || hovering { HoverPlayBadge(busy: busy).padding(10) }
                    }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(12)
                    .frame(width: width, height: band, alignment: .topLeading)
                    .background {
                        // The cover's own colours: its bottom, blurred and darkened.
                        artwork
                            .frame(width: width, height: width)
                            .blur(radius: 28)
                            .frame(width: width, height: band, alignment: .bottom)
                            .clipped()
                            .overlay(Color.black.opacity(0.3))
                    }
            }
            .clipShape(.rect(cornerRadius: 12))
            .shadow(color: .black.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 12 : 5, y: 4)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A square cover with its title and a line under it, as Apple Music's Recently Played.
struct MacCoverCard<Artwork: View>: View {
    let title: String
    var subtitle: String?
    var busy = false
    /// Whether a click plays (a play button shows on hover) rather than opening a page.
    var plays = true
    @ViewBuilder let artwork: Artwork
    @State private var hovering = false

    private let size: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    if busy || (plays && hovering) { HoverPlayBadge(busy: busy).padding(8) }
                }
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.12), radius: hovering ? 10 : 4, y: 3)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size, alignment: .leading)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A mood as a coloured card with its symbol, as Apple Music's categories.
struct MacMoodCard: View {
    let title: String
    let symbol: String
    let tint: Color
    var busy = false
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [tint, tint.mix(with: .black, by: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Darker under the title, so it reads on the light colours too.
            LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .center, endPoint: .bottom)
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(14)
            if busy {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 118)
        .clipShape(.rect(cornerRadius: 12))
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.12), radius: hovering ? 10 : 4, y: 3)
        .contentShape(.rect(cornerRadius: 12))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The round play button on a cover under the pointer (a spinner while it starts).
struct HoverPlayBadge: View {
    var busy = false

    var body: some View {
        Group {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "play.fill")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 36, height: 36)
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: .circle)
        .transition(.opacity)
    }
}
