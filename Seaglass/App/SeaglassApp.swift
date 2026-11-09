import SwiftUI
import UIKit

@main
struct SeaglassApp: App {
    // Plain references to the app-wide objects, not @StateObject: the views that show their state
    // observe them (see `appEnvironment`), while the app itself doesn't need to re-run its body every
    // time one changes. Computed, so they are still created after `init` has set up the URL cache.
    private var library: Library { .shared }
    private var lastfm: LastFM { .shared }
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
                .appEnvironment()
                .task {
                    // Warms YouTube's player script up front, so the first tapped song starts quickly too.
                    if let recent = library.history.first { StreamPrewarmer.shared.request(recent) }
                    await lastfm.flushPending()
                }
                .task { await updater.check(userInitiated: false) }
                #if targetEnvironment(macCatalyst)
                .onAppear {
                    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                        // On a Mac, a window no smaller than an iPad in landscape: the player's two columns fit.
                        scene.sizeRestrictions?.minimumSize = CGSize(width: 960, height: 640)
                        // No title over the glass: the tabs and pages say where you are.
                        scene.titlebar?.titleVisibility = .hidden
                        scene.titlebar?.toolbar = nil
                    }
                }
                #endif
        }
        // One window: on a Mac, where the app keeps playing with its window closed (see build.yml),
        // File › New Window would open a second one.
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

extension View {
    /// The app-wide objects the views read from their environment. Given to the app's root, and again
    /// to every view presented in a sheet or a cover: on a Mac (Mac Catalyst) they don't reach those
    /// by themselves, and a view that reads one would stop the app.
    @MainActor func appEnvironment() -> some View {
        let player = PlayerController.shared
        return environmentObject(player)
            .environmentObject(player.progress)
            .environmentObject(player.nowPlaying)
            .environmentObject(Library.shared)
            .environmentObject(DownloadManager.shared)
            .environmentObject(LastFM.shared)
            .environmentObject(AppRouter.shared)
            .environmentObject(LyricsTranslator.shared)
            .environmentObject(AppUpdater.shared)
    }
}
