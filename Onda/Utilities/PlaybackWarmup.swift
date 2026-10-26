import SwiftUI

/// A row owns an interest, not a playback job. Scrolling it away releases only
/// that interest, so another visible copy or an actual tap can keep shared work.
private struct PlaybackWarmup: ViewModifier {
    let track: Track?
    let priority: Int
    @Environment(\.scenePhase) private var scenePhase
    @State private var token = UUID()
    @State private var appeared = false
    /// True until a scroll view says otherwise: where it never reports (some lists), a row that
    /// appears is treated as visible, as before.
    @State private var visible = true
    @State private var debounce: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                visible = isVisible
                refresh()
            }
            .onAppear {
                appeared = true
                refresh()
            }
            .onDisappear {
                appeared = false
                release()
            }
            .onChange(of: scenePhase) { _, _ in refresh() }
            .onChange(of: track?.id) { _, _ in refresh() }
            .onChange(of: priority) { _, _ in refresh() }
    }

    private func refresh() {
        release()
        guard appeared, visible, scenePhase == .active, let track else { return }
        debounce = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            StreamPrewarmer.shared.request(track, token: token, priority: priority)
            PreparedPlayback.shared.offerVisible(track, token: token, priority: priority)
        }
    }

    private func release() {
        debounce?.cancel()
        debounce = nil
        StreamPrewarmer.shared.release(token)
        PreparedPlayback.shared.releaseVisible(token)
    }
}

extension View {
    func playbackWarmup(_ track: Track?, priority: Int = 0) -> some View {
        modifier(PlaybackWarmup(track: track, priority: priority))
    }
}
