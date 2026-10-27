import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var player: PlayerController
    @AppStorage(Preferences.songTransition) private var transition: SongTransition = Preferences.songTransitionSetting

    var body: some View {
        List {
            VStack(spacing: 10) {
                Toggle(isOn: $player.autoRadio) {
                    Label("Radio automatica", systemImage: "infinity")
                        .font(.subheadline.weight(.semibold))
                }
                Divider().opacity(0.4)
                Toggle(isOn: autoMix) {
                    Label("AutoMix", systemImage: "waveform.path")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))

            HStack {
                Text("Prossimi brani")
                    .font(.headline)
                Spacer()
                Button { player.toggleShuffle() } label: {
                    Label(player.shuffleEnabled ? "Casuale attivo" : "Casuale", systemImage: "shuffle")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(player.shuffleEnabled ? 0.25 : 0.1), in: .capsule)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 10, leading: 4, bottom: 4, trailing: 0))

            ForEach(player.upcoming) { entry in
                TrackRow(track: entry.track) { player.jump(to: entry.index) }
                    .padding(.horizontal, 10)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .padding(.vertical, 3)
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            .onDelete { player.removeUpcoming(atOffsets: $0) }
            .onMove { player.moveUpcoming(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .overlay {
            if player.upcoming.isEmpty {
                ContentUnavailableView(
                    "La coda è vuota", systemImage: "list.bullet",
                    description: Text(player.autoRadio
                        ? "Con la radio automatica arriveranno brani simili."
                        : "Aggiungi brani dal menu ··· di ogni canzone."))
            }
        }
    }

    /// AutoMix on or off, as in Apple Music's queue (off means no transitions).
    private var autoMix: Binding<Bool> {
        Binding {
            transition == .autoMix
        } set: { isOn in
            transition = isOn ? .autoMix : .off
            player.applyTransitionPreference()
        }
    }
}
