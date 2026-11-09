import SwiftUI

/// The player's tempo fader, laid out as a DJ app's (djay Pro's): the tempo in BPM (once the song is
/// measured) with the change in percent below it and the fader's range next to it, an upright fader
/// with notches, the dot beside it to go back to 0 and the note for the key lock, and − and + to nudge.
struct TempoView: View {
    @EnvironmentObject private var player: PlayerController
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    /// The playing song's own tempo, when AutoMix's analysis has measured it.
    private var bpm: Double? {
        guard let measured = player.songBPM, measured.trackID == player.current?.id else { return nil }
        return measured.bpm
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    header
                    HStack(spacing: 18) {
                        // Back to the song's own tempo.
                        Button { player.setSongTempo(0) } label: {
                            Image(systemName: player.songTempo == 0 ? "circle.fill" : "circle")
                                .font(.system(size: 12))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(Text("Reimposta"))
                        TempoFader(value: player.songTempo, limit: player.tempoLimit) { player.setSongTempo($0) }
                            .frame(width: 150, height: 230)
                        // The key lock: the note lit while voices keep their pitch.
                        Button { player.setKeyLock(!player.keyLock) } label: {
                            Image(systemName: "music.note")
                                .font(.title2)
                                .foregroundStyle(player.keyLock ? accent.color : Color.secondary)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(Text("Blocca tonalità"))
                        .accessibilityAddTraits(player.keyLock ? .isSelected : [])
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 48) {
                        Button { player.setSongTempo(player.songTempo - 0.001) } label: {
                            Image(systemName: "minus").font(.title2.weight(.semibold)).frame(width: 52, height: 36)
                        }
                        Button { player.setSongTempo(player.songTempo + 0.001) } label: {
                            Image(systemName: "plus").font(.title2.weight(.semibold)).frame(width: 52, height: 36)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                // The fader and its buttons the same way round in every language.
                .environment(\.layoutDirection, .leftToRight)
                .sensoryFeedback(.selection, trigger: player.songTempo == 0)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accelera o rallenta i brani fino al \(player.tempoLimit.formatted(.percent)), come il cursore del tempo di un'app da DJ. Resta così per tutti i brani finché non lo reimposti; i podcast hanno la loro velocità.")
                    Text("Con il tempo cambiato, AutoMix e la dissolvenza si fermano: i brani si susseguono senza mix.")
                }
            }
            Section {
                Toggle(isOn: Binding(get: { player.keyLock }, set: { player.setKeyLock($0) })) {
                    Label("Blocca tonalità", systemImage: "music.note")
                }
            } footer: {
                Text("La voce resta alla sua altezza a qualsiasi tempo. Disattivato, cambia con il tempo come su un giradischi: più veloce è più acuta, più lenta è più grave.")
            }
        }
        .navigationTitle("Tempo")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { player.measureSongBPM() }
    }

    /// "113.7" over "−0.9 % ⌄" (the fader's range in the menu); without a BPM, the percent alone.
    private var header: some View {
        VStack(spacing: 2) {
            if let bpm {
                Text(verbatim: (bpm * (1 + player.songTempo)).formatted(.number.precision(.fractionLength(1))))
                    .font(.system(size: 44, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
            } else if player.measuringBPM == player.current?.id {
                // The song's BPM on its way (its analysis).
                ProgressView()
                    .frame(height: 52)
                    .accessibilityLabel(Text(verbatim: "BPM"))
            }
            Menu {
                Picker("Intervallo", selection: Binding(get: { player.tempoLimit }, set: { player.setTempoLimit($0) })) {
                    ForEach(PlaybackTempo.ranges, id: \.self) { limit in
                        Text(verbatim: "±" + limit.formatted(.percent)).tag(limit)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: Self.percent(player.songTempo, digits: 1))
                        .font(bpm == nil ? .system(size: 44, weight: .semibold).monospacedDigit() : .title3.weight(.medium).monospacedDigit())
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .foregroundStyle(bpm == nil ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .animation(.snappy, value: player.songTempo)
    }

    /// "+4.5%", "−15%", "0%".
    static func percent(_ value: Double, digits: Int) -> String {
        value.formatted(.percent.precision(.fractionLength(0...digits)).sign(strategy: .always(includingZero: false)))
    }
}

/// An upright tempo fader, as on a turntable and in djay: the handle up for slower, down for faster,
/// notches every quarter of the range (the middle one, 0, brighter). Dragging moves it from where it
/// is, wherever it's grabbed, so it never jumps.
private struct TempoFader: View {
    let value: Double
    let limit: Double
    let onChange: (Double) -> Void
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @State private var dragStart: Double?

    private let handleHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let travel = max(1, geometry.size.height - handleHeight)
            let top = handleHeight / 2
            // -limit (slower) at the top, +limit at the bottom.
            let position = top + travel * CGFloat((min(limit, max(-limit, value)) / limit + 1) / 2)
            ZStack {
                ForEach(0..<9, id: \.self) { notch in
                    Rectangle()
                        .fill(Color.primary.opacity(notch == 4 ? 0.55 : 0.22))
                        .frame(width: notch % 2 == 0 ? width * 0.86 : width * 0.6, height: notch == 4 ? 2 : 1.5)
                        .position(x: width / 2, y: top + travel * CGFloat(notch) / 8)
                }
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 7, height: travel + 6)
                    .position(x: width / 2, y: geometry.size.height / 2)
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .overlay {
                        Capsule().fill(accent.color).frame(width: 14, height: 4)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .frame(width: width * 0.72, height: handleHeight)
                    .position(x: width / 2, y: position)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = start }
                        onChange(start + Double(drag.translation.height / travel) * 2 * limit)
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Tempo"))
        .accessibilityValue(Text(verbatim: TempoView.percent(value, digits: 1)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(value + 0.005)
            case .decrement: onChange(value - 0.005)
            @unknown default: break
            }
        }
    }
}
