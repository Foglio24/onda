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
    private var account: AccountService { .shared }
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // A bigger shared cache keeps cover art loaded by AsyncImage between screens.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20, directory: nil)
        _ = NetworkMonitor.shared
        Diagnostics.shared.start()
        #if targetEnvironment(macCatalyst)
        // A Mac's pages start beside the glass sidebar, where their navigation bars have no margin:
        // the large titles take the margin the lists have, rather than touching the page's edge.
        let margin = NSMutableParagraphStyle()
        margin.firstLineHeadIndent = 20
        margin.headIndent = 20
        UINavigationBar.appearance().largeTitleTextAttributes = [.paragraphStyle: margin]
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .appEnvironment()
                .task {
                    // The user's own songs: their folders opened, so a song from the history plays at once.
                    _ = LocalMusic.shared
                    // Warms YouTube's player script up front, so the first tapped song starts quickly too.
                    if let recent = library.history.first { StreamPrewarmer.shared.request(recent) }
                    await lastfm.flushPending()
                }
                .task { await updater.check(userInitiated: false) }
                // The account's library and preferences: brought in on opening, sent on leaving.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        account.appBecameActive()
                        // Songs copied into the folders with Files while Seaglass was away.
                        LocalMusic.shared.refresh(minimumInterval: 30)
                    case .background: account.appEnteredBackground()
                    default: break
                    }
                }
                #if targetEnvironment(macCatalyst)
                .onAppear {
                    // Seaglass in the menu bar: the song playing, its controls, and the window again.
                    MacBridge.shared.startMenuBar()
                    // The space bar plays or pauses anywhere, as in Apple Music.
                    MacBridge.shared.handleSpaceBar()
                    // Only the title bar moves the window: a drag on the volume moves the volume.
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        print("window: movable by background \(MacBridge.shared.keepWindowsInPlace())")
                    }
                    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                        // On a Mac, a window no smaller than an iPad in landscape: the player's two columns fit.
                        scene.sizeRestrictions?.minimumSize = LaunchScene.macWindowSize ?? CGSize(width: 960, height: 640)
                        if let previewSize = LaunchScene.macWindowSize {
                            scene.sizeRestrictions?.maximumSize = previewSize
                        }
                        // No title over the glass: the tabs and pages say where you are.
                        scene.titlebar?.titleVisibility = .hidden
                        scene.titlebar?.toolbar = nil
                        // No line under the window's buttons: they sit on the sidebar's glass.
                        scene.titlebar?.separatorStyle = .none
                    }
                }
                #endif
        }
        // One window: on a Mac, where the app keeps playing with its window closed (see build.yml),
        // File › New Window would open a second one.
        .commands {
            CommandGroup(replacing: .newItem) {}
            // The Mac's zoom, as Spotify's (see `MacZoom`).
            CommandGroup(after: .toolbar) {
                if ProcessInfo.processInfo.isMacCatalystApp {
                    Button("Ingrandisci") { MacZoom.step(1) }
                        .keyboardShortcut("+", modifiers: .command)
                    Button("Riduci") { MacZoom.step(-1) }
                        .keyboardShortcut("-", modifiers: .command)
                    Button("Dimensioni reali") { MacZoom.step(0) }
                        .keyboardShortcut("0", modifiers: .command)
                }
            }
        }
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
            .environmentObject(AccountService.shared)
            .modifier(MacZoomModifier())
            .modifier(InterfaceStyleModifier())
    }
}
