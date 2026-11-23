import AppIntents
import SwiftUI
import WidgetKit

// Seaglass's widgets (the SeaglassWidgets extension, embedded in the app): the song playing on the
// Home Screen, the lock screen and a Mac's desktop, and on an iPhone two controls for Control Center.
// The app writes what they show (see `SharedStore`, `WidgetFeed`) and asks them to reload when it
// changes; their buttons run in the app (see `WidgetCommands`).

@main
struct SeaglassWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        #if !targetEnvironment(macCatalyst)
        RecognizeControl()
        PlaybackControl()
        #endif
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let artwork: UIImage?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: .sample, artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        // In the gallery, before anything has played, a song shows what the widget is for.
        let snapshot = SharedStore.read()
        completion(NowPlayingEntry(date: .now, snapshot: snapshot ?? (context.isPreview ? .sample : nil),
                                   artwork: snapshot.flatMap(SharedStore.artwork)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let snapshot = SharedStore.read()
        let entry = NowPlayingEntry(date: .now, snapshot: snapshot, artwork: snapshot.flatMap(SharedStore.artwork))
        // No schedule of its own: the app reloads it when the song or its state changes.
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SeaglassWidgetKind.nowPlaying, provider: NowPlayingProvider()) { entry in
            NowPlayingFace(entry: entry)
        }
        .configurationDisplayName("In riproduzione")
        .description("Il brano in riproduzione, con i suoi comandi.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if targetEnvironment(macCatalyst)
        return [.systemSmall, .systemMedium]
        #else
        return [.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular]
        #endif
    }
}

/// Reads the family WidgetKit gives and hands it to the shared face.
private struct NowPlayingFace: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        NowPlayingWidgetView(snapshot: entry.snapshot, artwork: entry.artwork, family: family)
    }
}

#if !targetEnvironment(macCatalyst)
/// Control Center (and the lock screen's buttons): song recognition, opening Seaglass on it.
struct RecognizeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SeaglassWidgetKind.recognizeControl) {
            ControlWidgetButton(action: RecognizeSongIntent()) {
                Label("Riconosci un brano", systemImage: "waveform.badge.magnifyingglass")
            }
        }
        .displayName("Riconosci un brano")
    }
}

/// Control Center: play or pause what Seaglass plays, without opening it.
struct PlaybackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SeaglassWidgetKind.playbackControl) {
            ControlWidgetButton(action: TogglePlaybackIntent()) {
                Label("Riproduci o metti in pausa", systemImage: "playpause.fill")
            }
        }
        .displayName("Riproduci o metti in pausa")
    }
}
#endif
