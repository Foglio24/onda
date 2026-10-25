import SwiftUI

struct LyricsView: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        Group {
            switch player.lyrics {
            case .idle, .loading:
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .synced(let lines):
                SyncedLyrics(lines: lines)
            case .plain(let text):
                ScrollView {
                    Text(text)
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 32)
                }
                .scrollIndicators(.hidden)
            case .unavailable:
                ContentUnavailableView("Testo non disponibile", systemImage: "quote.bubble",
                                       description: Text("LRCLIB non ha il testo di questo brano."))
            }
        }
        // Fade lines in and out at the edges.
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Karaoke-style lyrics: the current line lights up and stays centred; tap a line to jump there.
private struct SyncedLyrics: View {
    let lines: [LyricLine]
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var progress: PlaybackProgress

    /// Lines are sorted by time and their ids are their positions.
    private var activeID: Int? {
        lines.last(where: { $0.time <= progress.currentTime + 0.25 })?.id
    }

    var body: some View {
        let currentID = activeID
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(lines) { line in
                        let active = line.id == currentID
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(active ? 1 : 0.32))
                            .blur(radius: active ? 0 : 0.8)
                            .scaleEffect(active ? 1 : 0.94, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .onTapGesture { player.seek(to: line.time) }
                            .animation(.spring(duration: 0.5, bounce: 0.2), value: active)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 160)
            }
            .scrollIndicators(.hidden)
            .onChange(of: currentID) { _, id in
                guard let id else { return }
                withAnimation(.spring(duration: 0.6)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                if let currentID { proxy.scrollTo(currentID, anchor: .center) }
            }
        }
    }
}
