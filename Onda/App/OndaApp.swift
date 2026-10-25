import SwiftUI

@main
struct OndaApp: App {
    @StateObject private var player = PlayerController.shared
    @StateObject private var library = Library.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var lastfm = LastFM.shared
    @StateObject private var router = AppRouter.shared
    @StateObject private var translator = LyricsTranslator.shared

    init() {
        // A bigger shared cache keeps cover art loaded by AsyncImage between screens.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20, directory: nil)
        _ = NetworkMonitor.shared
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
                .task {
                    // Warms YouTube's player script up front, so the first tapped song starts quickly too.
                    if let recent = library.history.first { StreamPrewarmer.shared.request(recent) }
                    await lastfm.flushPending()
                }
        }
    }
}
