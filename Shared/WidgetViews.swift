import AppIntents
import SwiftUI
import WidgetKit

/// The "In riproduzione" widget's faces. Built into the app too, which draws them for CI's screenshots
/// (see `WidgetGalleryPreview`): the family is passed in, as only WidgetKit can set its environment.
struct NowPlayingWidgetView: View {
    /// Nil: nothing has played yet (or there is no shared folder: see `SharedStore`).
    let snapshot: WidgetSnapshot?
    let artwork: UIImage?
    let family: WidgetFamily

    private var tint: Color { snapshot?.tintColor ?? .pink }
    private var isPlaying: Bool { snapshot?.isPlaying ?? false }

    var body: some View {
        content
            .widgetURL(WidgetLink.player)
            .containerBackground(for: .widget) { faceBackground }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .systemMedium, .systemLarge, .systemExtraLarge: medium
        #if !targetEnvironment(macCatalyst)
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        #endif
        default: small
        }
    }

    // MARK: Faces

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Spacer(minLength: 0)
                playButton(size: 40)
            }
            Spacer(minLength: 0)
            titles(alignment: .leading, titleFont: .headline, lines: 2)
        }
        .foregroundStyle(.white)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            cover
                .frame(width: 118, height: 118)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 10) {
                // Only over a song: over "Niente in riproduzione" it would say the opposite.
                if snapshot?.title.isEmpty == false {
                    Text("In riproduzione")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                titles(alignment: .leading, titleFont: .headline, lines: 2)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    playButton(size: 42)
                    Button(intent: NextTrackIntent()) {
                        Image(systemName: "forward.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.18), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Brano successivo"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
    }

    #if !targetEnvironment(macCatalyst)
    private var rectangular: some View {
        HStack(spacing: 8) {
            titles(alignment: .leading, titleFont: .headline, lines: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(intent: TogglePlaybackIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Riproduci o metti in pausa"))
        }
    }

    private var circular: some View {
        Button(intent: TogglePlaybackIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Riproduci o metti in pausa"))
    }
    #endif

    // MARK: Pieces

    private func titles(alignment: HorizontalAlignment, titleFont: Font, lines: Int) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if let snapshot, !snapshot.title.isEmpty {
                Text(snapshot.title)
                    .font(titleFont)
                    .lineLimit(lines)
                Text(snapshot.artist)
                    .font(.caption)
                    .opacity(0.8)
                    .lineLimit(1)
            } else {
                Text("Niente in riproduzione")
                    .font(titleFont)
                    .lineLimit(lines)
                Text("Apri Seaglass")
                    .font(.caption)
                    .opacity(0.8)
                    .lineLimit(1)
            }
        }
        .minimumScaleFactor(0.85)
    }

    private func playButton(size: CGFloat) -> some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(.white, in: .circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Riproduci o metti in pausa"))
    }

    @ViewBuilder private var cover: some View {
        if let artwork {
            Image(uiImage: artwork)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [tint, tint.mix(with: .black, by: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    /// The cover full-bleed under the small face, darkened at the bottom for the title; under the
    /// medium one, the theme's colour deepened. Plain on the lock screen.
    @ViewBuilder fileprivate var faceBackground: some View {
        switch family {
        case .systemSmall:
            ZStack {
                cover
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .center)
            }
        case .systemMedium, .systemLarge, .systemExtraLarge:
            ZStack {
                LinearGradient(colors: [tint.mix(with: .black, by: 0.25), tint.mix(with: .black, by: 0.65)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 30)
                        .opacity(0.45)
                }
                Color.black.opacity(0.15)
            }
        default:
            Color.clear
        }
    }
}

/// CI's look at the widgets inside the app (the scene "widgets": see `LaunchScene`), at their sizes on
/// an iPhone, with and without a song, so they can be checked in a screenshot.
struct WidgetGalleryPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 18) {
                    face(.systemSmall, WidgetSnapshot.sample, width: 170, height: 170)
                    face(.systemSmall, nil, width: 170, height: 170)
                }
                face(.systemMedium, WidgetSnapshot.sample, width: 364, height: 170)
                face(.systemMedium, nil, width: 364, height: 170)
            }
            .padding(24)
        }
        .background(LinearGradient(colors: [.indigo, .teal], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func face(_ family: WidgetFamily, _ snapshot: WidgetSnapshot?, width: CGFloat, height: CGFloat) -> some View {
        // The container background only applies inside WidgetKit: here it is drawn as the system would.
        NowPlayingWidgetView(snapshot: snapshot, artwork: nil, family: family)
            .padding(16)
            .frame(width: width, height: height)
            .background {
                NowPlayingWidgetView.previewBackground(snapshot: snapshot, family: family)
            }
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
    }
}

extension NowPlayingWidgetView {
    /// The background `containerBackground` gives the widget, for `WidgetGalleryPreview`.
    static func previewBackground(snapshot: WidgetSnapshot?, family: WidgetFamily) -> some View {
        NowPlayingWidgetView(snapshot: snapshot, artwork: nil, family: family).faceBackground
    }
}
