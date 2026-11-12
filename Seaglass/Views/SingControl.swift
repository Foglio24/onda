import SwiftUI

/// The karaoke as Apple Music's Sing, beside the lyrics on iPhone and iPad: a slider for the voice.
/// Dragged down the voice gets softer all the way, gone at the bottom; up it comes back, the song as
/// it is at the top. A tap turns it on (without the voice) or off, and holding it offers the voice
/// alone. Where Premium is needed and missing, it explains Premium.
struct SingControl: View {
    @EnvironmentObject private var player: PlayerController
    @ObservedObject private var account = AccountService.shared
    @Binding var paywall: PremiumFeature?
    /// The voice's level when the drag began.
    @State private var dragStart: Double?

    private static let height: CGFloat = 132
    private static let width: CGFloat = 48

    /// The slider's position: 1 the song as it is, 0 without the voice. The voice's volume is its
    /// cube, a loudness taper: half way down it is 18 dB softer, so the whole travel is heard (a
    /// straight volume would sound nearly the same down to the last quarter, then drop).
    private var level: Double {
        player.karaokeMode == .noVocals ? cbrt(max(0, 1 - Double(player.karaokeAmount))) : 1
    }

    private var unlocked: Bool { account.unlocks(.karaoke) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(Color.white.opacity(0.14))
            // The voice that's left, from the bottom.
            Capsule()
                .fill(Color.white.opacity(player.karaokeMode == .off ? 0.35 : 0.9))
                .frame(height: max(Self.width, Self.height * level))
            icon
                .frame(width: Self.width, height: Self.width)
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(.capsule)
        .styledSurface(in: .capsule)
        .overlay(alignment: .topTrailing) {
            if !unlocked { PremiumLock().offset(x: 4, y: -4) }
        }
        .contentShape(.capsule)
        .onTapGesture { toggle() }
        // Before the lyrics' scrolling and the player's own drags, which would take a vertical drag.
        .highPriorityGesture(drag)
        .contextMenu {
            Picker("Karaoke", selection: Binding(get: { player.karaokeMode }, set: { choose($0) })) {
                ForEach(KaraokeMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: level)
        .accessibilityElement()
        .accessibilityLabel(Text("Karaoke"))
        .accessibilityValue(Text(player.karaokeMode.title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(level: min(1, level + 0.25))
            case .decrement: set(level: max(0, level - 0.25))
            @unknown default: break
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch player.karaokeStatus {
        case .preparing:
            ProgressView().controlSize(.small).tint(player.karaokeMode == .off ? .white : .black)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ready, .idle:
            Image(systemName: player.karaokeMode == .vocalsOnly ? "music.mic" : "mic.and.signal.meter.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(player.karaokeMode == .off ? Color.white : Color.black.opacity(0.75))
        }
    }

    /// A drag up or down sets the voice (a tap turns it on or off).
    private var drag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard unlocked else {
                    paywall = .karaoke
                    return
                }
                if dragStart == nil { dragStart = level }
                set(level: (dragStart ?? level) - Double(value.translation.height / Self.height))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func toggle() {
        guard unlocked else {
            paywall = .karaoke
            return
        }
        choose(player.karaokeMode == .off ? .noVocals : .off)
    }

    private func choose(_ mode: KaraokeMode) {
        guard unlocked else {
            paywall = .karaoke
            return
        }
        if mode != .off, player.karaokeAmount < 0.25 { player.setKaraokeAmount(1) }
        player.setKaraoke(mode)
    }

    /// The voice at this position, the karaoke staying on all the way (at the top the song plays as
    /// it is from its parts): turning it off while dragging would change the song's file under the
    /// finger. A tap turns it off.
    private func set(level newLevel: Double) {
        guard unlocked else { return }
        let level = min(1, max(0, newLevel))
        if player.karaokeMode != .noVocals { player.setKaraoke(.noVocals) }
        player.setKaraokeAmount(Float(1 - level * level * level))
    }
}
