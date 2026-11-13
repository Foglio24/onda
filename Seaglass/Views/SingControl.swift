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

/// While the karaoke separates the song's voice from its music (it takes a while the first time):
/// a card at the top of the player, on every page of it (the cover, the lyrics, the queue), with a
/// ring filling up as it goes, the voice's waves being drawn apart, how far it is and how long it
/// has left. Its × turns the karaoke off. It shows only while it prepares; the badge under the cover
/// says the rest.
struct KaraokePreparingCard: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        Group {
            if case .preparing(let value, let remaining) = player.karaokeStatus, player.karaokeMode != .off {
                card(value: value, remaining: remaining)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: isPreparing)
    }

    private var isPreparing: Bool {
        if case .preparing = player.karaokeStatus { return player.karaokeMode != .off }
        return false
    }

    private func card(value: Double, remaining: TimeInterval?) -> some View {
        HStack(spacing: 14) {
            ProgressRing(value: value)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text("Preparazione del karaoke")
                    .font(.subheadline.weight(.semibold))
                Text("La voce viene separata dalla musica")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 8) {
                    VoiceWaves(progress: value)
                        .frame(height: 14)
                    Text(Self.detail(value, remaining: remaining))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
            Button {
                player.setKaraoke(.off)
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Annulla"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .styledSurface(in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
    }

    /// "35% · 12 s" (or "1 min"); just the share at first, before the time left is known.
    private static func detail(_ value: Double, remaining: TimeInterval?) -> String {
        var text = max(0, min(1, value)).formatted(.percent.precision(.fractionLength(0)))
        if let remaining {
            text += remaining < 60 ? " · \(max(1, Int(remaining))) s" : " · \(Int((remaining / 60).rounded())) min"
        }
        return text
    }

    /// The share done as a ring around a breathing microphone.
    private struct ProgressRing: View {
        let value: Double

        var body: some View {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let breath = 1 + 0.08 * sin(t * 2 * .pi / 1.6)
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.04, min(1, value))))
                        .stroke(AngularGradient(colors: [.pink, .purple, .orange, .pink], center: .center),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth(duration: 0.5), value: value)
                    Image(systemName: "music.mic")
                        .font(.system(size: 18, weight: .semibold))
                        .scaleEffect(CGFloat(breath))
                }
            }
        }
    }

    /// Bars moving like a voice: the done share of them in colour, the rest dim, so the waves fill
    /// from left to right as the voice is drawn apart from the music.
    private struct VoiceWaves: View {
        let progress: Double
        private static let count = 22

        var body: some View {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<Self.count, id: \.self) { index in
                        let x = Double(index)
                        let height = 0.3 + 0.7 * abs(sin(t * 3.1 + x * 0.55) * cos(t * 1.7 + x * 0.23))
                        Capsule()
                            .fill(Double(index) / Double(Self.count) < progress
                                  ? AnyShapeStyle(LinearGradient(colors: [.pink, .purple], startPoint: .bottom, endPoint: .top))
                                  : AnyShapeStyle(Color.primary.opacity(0.2)))
                            .frame(width: 3)
                            .scaleEffect(x: 1, y: CGFloat(height), anchor: .center)
                    }
                }
            }
        }
    }
}
