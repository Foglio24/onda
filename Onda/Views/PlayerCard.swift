import SwiftUI
import UIKit

/// What the player asks of the card it sits on: follow a drag, finish it, or close.
struct PlayerCardActions {
    /// How far the finger has moved down since the drag began.
    let drag: (CGFloat) -> Void
    /// The finger lifted: close, or spring back open. Distance moved and the flick's predicted end.
    let release: (_ distance: CGFloat, _ predicted: CGFloat) -> Void
    let close: () -> Void
}

extension EnvironmentValues {
    /// Set by `PlayerCard`; nil when the player is shown some other way.
    @Entry var playerCard: PlayerCardActions? = nil
}

/// The full-screen player as a card that grows out of the mini player and shrinks back into it,
/// like Spotify's: it rises from the mini player's place at the bottom to fill the screen, and
/// going down it follows the finger, getting smaller as it nears the mini player. The app stays
/// visible behind it. It sits in a full-screen cover with a clear background, presented without
/// the system's animation (see `AppRouter.openPlayer`).
struct PlayerCard: View {
    @EnvironmentObject private var router: AppRouter
    /// 0: the card is the mini player; 1: it fills the screen.
    @State private var progress: CGFloat = 0
    @State private var closing = false
    @State private var screenHeight: CGFloat = 800
    /// The card spans the whole screen, status bar included, so it can shrink as one piece; the
    /// player inside gets the screen's safe area back from these.
    @State private var insets = PlayerCard.windowInsets

    var body: some View {
        GeometryReader { geometry in
            let screen = geometry.frame(in: .global)
            let card = frame(at: progress, screen: screen)
            let scale = max(0.01, card.width / max(screen.width, 1))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.3 * progress)
                    .allowsHitTesting(false)
                NowPlayingView()
                    .safeAreaPadding(insets)
                    .frame(width: screen.width, height: screen.height)
                    // Fades out as the card nears the mini player, so it lands as a plain card.
                    .opacity(min(1, max(0, (progress - 0.08) / 0.3)))
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: card.width, height: card.height, alignment: .topLeading)
                    .background(.regularMaterial)
                    .clipShape(.rect(cornerRadius: cornerRadius(card)))
                    .offset(x: card.minX - screen.minX, y: card.minY - screen.minY)
                    .allowsHitTesting(!closing)
            }
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
        .environment(\.playerCard, PlayerCardActions(drag: follow, release: release, close: close))
        .onAppear {
            // The CI screenshots can stop the card part of the way (see `LaunchScene`).
            let target = LaunchScene.playerCardProgress ?? 1
            withAnimation(.spring(duration: 0.5, bounce: 0.12)) { progress = target }
        }
    }

    private static var windowInsets: EdgeInsets {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let insets = window?.safeAreaInsets ?? .zero
        return EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }

    /// Between the mini player's frame and the whole screen.
    private func frame(at progress: CGFloat, screen: CGRect) -> CGRect {
        let mini = miniPlayerFrame(in: screen)
        func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * progress }
        return CGRect(x: mix(mini.minX, screen.minX), y: mix(mini.minY, screen.minY),
                      width: mix(mini.width, screen.width), height: mix(mini.height, screen.height))
    }

    /// Where the mini player is on screen, or where it usually sits when that isn't known yet.
    private func miniPlayerFrame(in screen: CGRect) -> CGRect {
        let known = router.miniPlayerFrame
        if known.width > 0, known.height > 0, screen.intersects(known) { return known }
        return CGRect(x: screen.minX + 16, y: screen.maxY - 140, width: screen.width - 32, height: 56)
    }

    /// The mini player's capsule ends up as the screen's rounded corners.
    private func cornerRadius(_ card: CGRect) -> CGFloat {
        let mini = router.miniPlayerFrame.height > 0 ? router.miniPlayerFrame.height / 2 : 28
        return mini + (50 - mini) * progress
    }

    // MARK: Actions

    private func follow(_ distance: CGFloat) {
        guard !closing else { return }
        let height = max(screenHeight, 1)
        progress = max(0, min(1, 1 - max(0, distance) / (height * 0.85)))
    }

    private func release(_ distance: CGFloat, _ predicted: CGFloat) {
        if distance > 120 || predicted > 260 {
            close()
        } else {
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) { progress = 1 }
        }
    }

    /// Shrinks back into the mini player, then removes the cover without another animation.
    private func close() {
        guard !closing else { return }
        closing = true
        withAnimation(.spring(duration: 0.42, bounce: 0)) {
            progress = 0
        } completion: {
            router.closePlayerNow()
        }
    }
}
