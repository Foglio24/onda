import SwiftUI

/// When each playlist was last opened, so the Home's quick access shows the ones in use.
enum PlaylistUsage {
    private static let key = "home.playlistOpened"

    static func noteOpened(_ id: UUID) {
        var dates = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        dates[id.uuidString] = Date.now.timeIntervalSince1970
        UserDefaults.standard.set(dates, forKey: key)
    }

    /// Most recently opened first; never opened ones keep the library's order after them.
    static func sorted(_ playlists: [Playlist]) -> [Playlist] {
        let dates = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return playlists.enumerated().sorted { a, b in
            let first = dates[a.element.id.uuidString] ?? 0
            let second = dates[b.element.id.uuidString] ?? 0
            return first != second ? first > second : a.offset < b.offset
        }.map(\.element)
    }
}

/// A tile of the Home's quick access grid.
enum HomeShortcut: Identifiable {
    case liked, downloads, tasteMix, rediscover, topMonth
    case playlist(Playlist)

    var id: String {
        switch self {
        case .liked: return "liked"
        case .downloads: return "downloads"
        case .tasteMix: return "taste"
        case .rediscover: return "rediscover"
        case .topMonth: return "top"
        case .playlist(let playlist): return "playlist-\(playlist.id.uuidString)"
        }
    }
}

/// A mix built from the user's own listening: one per most-played artist, starting each day
/// from a different song of theirs, followed by YouTube Music's radio of similar songs.
/// Compact quick access tile: artwork on the left, title on the right, on Liquid Glass.
struct ShortcutTile<Artwork: View>: View {
    let title: String
    var busy = false
    @ViewBuilder let artwork: Artwork
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        if style == .classic { classic } else { seaglass }
    }

    /// Flat and grey, the cover against the left edge, the name in bold: the common streaming apps' shortcut.
    private var classic: some View {
        HStack(spacing: 10) {
            artwork
                .frame(width: 56, height: 56)
            Text(title)
                .font(.footnote.weight(.bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.small).padding(.trailing, 8) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClassicPalette.elevated)
        .clipShape(.rect(cornerRadius: 4))
        .contentShape(.rect(cornerRadius: 4))
    }

    private var seaglass: some View {
        HStack(spacing: 10) {
            artwork
                .frame(width: 50, height: 50)
                .clipShape(.rect(cornerRadius: 10))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(6)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect(cornerRadius: 16))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
    }
}

/// Square artwork made of a symbol on a coloured gradient, for tiles that aren't playlists.
struct SymbolArtwork: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Rectangle()
            .fill(tint.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// The last song and where it stopped, with a button to carry on.
struct ResumeCard: View {
    let point: PlayerController.ResumePoint
    let accent: Color
    let action: () -> Void
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        if style == .classic {
            // Flat square cover card with the song under it, as "Continua ad ascoltare".
            Button(action: action) {
                VStack(alignment: .leading, spacing: 8) {
                    ArtworkView(track: point.track, size: 152, cornerRadius: 4)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.title3)
                                .foregroundStyle(.black)
                                .frame(width: 40, height: 40)
                                .background(ClassicPalette.accent, in: .circle)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                .padding(10)
                        }
                    Text(point.track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ClassicPalette.primaryText)
                        .lineLimit(2)
                    Text(point.track.artist)
                        .font(.caption)
                        .foregroundStyle(ClassicPalette.secondaryText)
                        .lineLimit(1)
                }
                .frame(width: 152, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Riprendi \(point.track.title)"))
        } else {
            let radius: CGFloat = 22
            Button(action: action) {
                HStack(spacing: 14) {
                    ArtworkView(track: point.track, size: 68, cornerRadius: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(point.track.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(point.track.artist) · fermo a \(point.time.formattedTime)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let length = point.track.duration, length > 0 {
                            ProgressView(value: min(max(point.time / length, 0), 1))
                                .tint(accent)
                                .padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(accent.gradient, in: .circle)
                }
                .padding(12)
                .contentShape(.rect(cornerRadius: radius))
                .styledSurface(in: .rect(cornerRadius: radius), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Riprendi \(point.track.title)"))
        }
    }
}

/// A daily mix: the mosaic of the artist's songs with a glass "Mix N" badge (Seaglass), or a flat
/// square cover and a "Playlist" line under the name (classic).
struct DailyMixCard: View {
    let mix: DailyMix
    let busy: Bool
    @Environment(\.interfaceStyle) private var style

    private var cover: Playlist {
        Playlist(id: UUID(), name: mix.artist, tracks: mix.covers, createdAt: .distantPast)
    }

    var body: some View {
        let size: CGFloat = style == .classic ? 152 : 150
        VStack(alignment: .leading, spacing: style == .classic ? 8 : 6) {
            PlaylistArtwork(playlist: cover, size: size, cornerRadius: style == .classic ? 4 : 18)
                .overlay(alignment: .bottomLeading) {
                    if style != .classic {
                        Text("Mix \(mix.number)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
                            .padding(8)
                    }
                }
                .overlay {
                    if busy {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.black.opacity(0.35), in: .circle)
                    }
                }
            if style == .classic {
                Text("Mix \(mix.number) · \(mix.artist)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ClassicPalette.primaryText)
                    .lineLimit(2)
                Text("Playlist")
                    .font(.caption)
                    .foregroundStyle(ClassicPalette.secondaryText)
                    .lineLimit(1)
            } else {
                Text("\(mix.artist) e simili")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .frame(width: size, alignment: .leading)
        .contentShape(.rect)
    }
}
