import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.playerTextScale) private var playerTextScale
    @AppStorage(Preferences.songTransition) private var transition: SongTransition = Preferences.songTransitionSetting
    @ObservedObject private var account = AccountService.shared
    @State private var paywall: PremiumFeature?

    var body: some View {
        List {
            VStack(spacing: 10) {
                Toggle(isOn: $player.autoRadio) {
                    Label("Radio automatica", systemImage: "infinity")
                        .font(controlFont)
                }
                Divider().opacity(0.4)
                Toggle(isOn: autoMix) {
                    HStack(spacing: 8) {
                        Label("AutoMix", systemImage: "waveform.path")
                            .font(controlFont)
                        if !account.unlocks(.autoMix) { PremiumLock() }
                    }
                }
                if autoMix.wrappedValue, let note = player.autoMixNote {
                    Text(note)
                        .font(textScale == 1 ? .caption : .system(size: 12 * textScale))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // A translucent card, as the songs' rows below: Liquid Glass inside a list row was cut
            // by the row's square edges, which showed at its corners.
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))

            HStack {
                Text("Prossimi brani")
                    .font(textScale == 1 ? .headline : .system(size: 17 * textScale, weight: .semibold))
                Spacer()
                Button { player.toggleShuffle() } label: {
                    Label(player.shuffleEnabled ? "Casuale attivo" : "Casuale", systemImage: "shuffle")
                        .font(textScale == 1 ? .footnote.weight(.semibold) : .system(size: 13 * textScale, weight: .semibold))
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

            if player.upcoming.isEmpty {
                // A row under the header: laid over the list, it covered the header and Shuffle in
                // the iPhone's short panel.
                ContentUnavailableView(
                    "La coda è vuota", systemImage: "list.bullet",
                    description: Text(player.autoRadio
                        ? "Con la radio automatica arriveranno brani simili."
                        : "Aggiungi brani dal menu ··· di ogni canzone."))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(player.upcoming) { entry in
                TrackRow(track: entry.track, queues: false, remove: {
                    if let offset = player.upcoming.firstIndex(where: { $0.id == entry.id }) {
                        player.removeUpcoming(atOffsets: IndexSet(integer: offset))
                    }
                }) { player.jump(to: entry.index) }
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
        .premiumPaywall($paywall)
    }

    private var textScale: CGFloat { min(playerTextScale, 1.4) }

    private var controlFont: Font {
        textScale == 1 ? .subheadline.weight(.semibold) : .system(size: 15 * textScale, weight: .semibold)
    }

    /// AutoMix on or off, as in Apple Music's queue (off means no transitions). Where it needs
    /// Premium and there is none, it shows off and turning it on explains Premium.
    private var autoMix: Binding<Bool> {
        Binding {
            transition == .autoMix && account.unlocks(.autoMix)
        } set: { isOn in
            if isOn, !account.unlocks(.autoMix) {
                paywall = .autoMix
                return
            }
            transition = isOn ? .autoMix : .off
            player.applyTransitionPreference()
        }
    }
}
