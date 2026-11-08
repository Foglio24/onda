import SwiftUI

/// The player's tempo fader, as in a DJ app (djay Pro's): the songs up to 15 % faster or slower, the
/// song's tempo in BPM once it's measured, and the key lock.
struct TempoView: View {
    @EnvironmentObject private var player: PlayerController

    private var tempo: Binding<Double> {
        Binding(get: { player.songTempo }, set: { player.setSongTempo($0) })
    }

    /// The playing song's own tempo, when AutoMix's analysis has measured it.
    private var bpm: Double? {
        guard let measured = player.songBPM, measured.trackID == player.current?.id else { return nil }
        return measured.bpm
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Text(verbatim: Self.percent(player.songTempo, digits: 1))
                        .font(.system(size: 44, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                    if let bpm {
                        Text(verbatim: Self.bpmLine(bpm, tempo: player.songTempo))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: tempo, in: PlaybackTempo.range, step: 0.001) {
                        Text("Tempo")
                    } minimumValueLabel: {
                        Text(verbatim: Self.percent(PlaybackTempo.range.lowerBound, digits: 0)).font(.caption)
                    } maximumValueLabel: {
                        Text(verbatim: Self.percent(PlaybackTempo.range.upperBound, digits: 0)).font(.caption)
                    }
                    // Faster to the right in every language, as on a DJ app's fader.
                    .environment(\.layoutDirection, .leftToRight)
                    HStack {
                        Button { player.setSongTempo(player.songTempo - 0.001) } label: {
                            Image(systemName: "minus").frame(width: 28, height: 20)
                        }
                        Spacer()
                        Button("Reimposta") { player.setSongTempo(0) }
                            .disabled(player.songTempo == 0)
                        Spacer()
                        Button { player.setSongTempo(player.songTempo + 0.001) } label: {
                            Image(systemName: "plus").frame(width: 28, height: 20)
                        }
                    }
                    .buttonStyle(.bordered)
                    .environment(\.layoutDirection, .leftToRight)
                }
                .padding(.vertical, 8)
                .animation(.snappy, value: player.songTempo)
            } footer: {
                Text("Accelera o rallenta i brani fino al \(PlaybackTempo.range.upperBound.formatted(.percent)), come il cursore del tempo di un'app da DJ. Resta così per tutti i brani finché non lo reimposti; i podcast hanno la loro velocità.")
            }
            Section {
                Toggle(isOn: Binding(get: { player.keyLock }, set: { player.setKeyLock($0) })) {
                    Label("Blocca tonalità", systemImage: "tuningfork")
                }
            } footer: {
                Text("La voce resta alla sua altezza a qualsiasi tempo. Disattivato, cambia con il tempo come su un giradischi: più veloce è più acuta, più lenta è più grave.")
            }
        }
        .navigationTitle("Tempo")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { player.measureSongBPM() }
    }

    /// "+4,5%", "−15%", "0%".
    static func percent(_ value: Double, digits: Int) -> String {
        value.formatted(.percent.precision(.fractionLength(0...digits)).sign(strategy: .always(includingZero: false)))
    }

    /// "113,6 → 118,7 BPM", or the song's own tempo alone at 0.
    static func bpmLine(_ bpm: Double, tempo: Double) -> String {
        let own = bpm.formatted(.number.precision(.fractionLength(1)))
        guard tempo != 0 else { return "\(own) BPM" }
        return "\(own) → \((bpm * (1 + tempo)).formatted(.number.precision(.fractionLength(1)))) BPM"
    }
}
