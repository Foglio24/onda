import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        List {
            Toggle(isOn: $player.autoRadio) {
                Label("Radio automatica", systemImage: "infinity")
            }
            .tint(.pink)
            .listRowBackground(Color.white.opacity(0.08))

            Section {
                ForEach(player.upcoming) { entry in
                    Button { player.jump(to: entry.index) } label: {
                        TrackRow(track: entry.track)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { player.removeUpcoming(atOffsets: $0) }
                .onMove { player.moveUpcoming(fromOffsets: $0, toOffset: $1) }
                .listRowBackground(Color.clear)
            } header: {
                HStack {
                    Text("Prossimi brani")
                    Spacer()
                    Button { player.shuffleUpcoming() } label: {
                        Label("Mescola", systemImage: "shuffle")
                    }
                    .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if player.upcoming.isEmpty {
                ContentUnavailableView(
                    "La coda è vuota", systemImage: "list.bullet",
                    description: Text(player.autoRadio
                        ? "Con la radio automatica arriveranno brani simili."
                        : "Aggiungi brani dal menu di ogni canzone."))
            }
        }
    }
}
