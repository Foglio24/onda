import SwiftUI

/// The karaoke as Apple Music's Sing, beside the lyrics on iPhone and iPad: a slider for the voice.
/// Down takes the voice away, up brings it back; a tap turns it on (without the voice) or off, and
/// holding it offers the voice alone. Where Premium is needed and missing, it explains Premium.
struct SingControl: View {
    @EnvironmentObject private var player: PlayerController
    @ObservedObject private var account = AccountService.shared
    @Binding var paywall: PremiumFeature?
    /// The voice's level when the drag began.
    @State private var dragStart: Double?

    private static let height: CGFloat = 132
    private static let width: CGFloat = 48

    /// The voice's level: 1 as the song is, 0 without it.
    private var level: Double {
        player.karaokeMode == .noVocals ? 1 - Double(player.karaokeAmount) : 1
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
        .glassEffect(.regular, in: .capsule)
        .overlay(alignment: .topTrailing) {
            if !unlocked { PremiumLock().offset(x: 4, y: -4) }
        }
        .contentShape(.capsule)
        .gesture(drag)
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

    /// A tap (no movement) turns it on or off; a drag up or down sets the voice.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard unlocked, abs(value.translation.height) > 3 else { return }
                if dragStart == nil { dragStart = level }
                set(level: (dragStart ?? level) - Double(value.translation.height / Self.height))
            }
            .onEnded { value in
                defer { dragStart = nil }
                guard abs(value.translation.height) <= 3 else { return }
                toggle()
            }
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

    /// Nearly all the voice is the song as it is; any less takes it away by that much.
    private func set(level newLevel: Double) {
        guard unlocked else { return }
        let level = min(1, max(0, newLevel))
        if level > 0.96 {
            if player.karaokeMode != .off { player.setKaraoke(.off) }
            return
        }
        if player.karaokeMode != .noVocals { player.setKaraoke(.noVocals) }
        player.setKaraokeAmount(Float(1 - level))
    }
}
