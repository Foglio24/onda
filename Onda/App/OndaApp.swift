import SwiftUI

@main
struct OndaApp: App {
    // Plain references to the app-wide objects, not @StateObject: the views that show their state
    // observe them, while the app itself doesn't need to re-run its body every time one changes.
    // Computed, so they are still created after `init` has set up the URL cache.
    private var player: PlayerController { .shared }
    private var library: Library { .shared }
    private var downloads: DownloadManager { .shared }
    private var lastfm: LastFM { .shared }
    private var router: AppRouter { .shared }
    private var translator: LyricsTranslator { .shared }
    private var updater: AppUpdater { .shared }

    init() {
        // A bigger shared cache keeps cover art loaded by AsyncImage between screens.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20, directory: nil)
        _ = NetworkMonitor.shared
        Diagnostics.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(player.progress)
                .environmentObject(library)
                .environmentObject(downloads)
                .environmentObject(lastfm)
                .environmentObject(router)
                .environmentObject(translator)
                .environmentObject(updater)
                .task {
                    // Warms YouTube's player script up front, so the first tapped song starts quickly too.
                    if let recent = library.history.first { StreamPrewarmer.shared.request(recent) }
                    await lastfm.flushPending()
                }
                .task { await updater.check(userInitiated: false) }
        }
    }
}
