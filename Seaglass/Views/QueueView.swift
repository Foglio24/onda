import SwiftUI

struct QueueView: View {
    /// Classic Mac's right panel already draws "Stai ascoltando" and the section title above;
    /// skip the duplicate chrome inside the list.
    var macSidePanel: Bool = false

    @EnvironmentObject private var player: PlayerController
    @Environment(\.playerTextScale) private var playerTextScale
    @Environment(\.interfaceStyle) private var style
    @AppStorage(Preferences.songTransition) private var transition: SongTransition = Preferences.songTransitionSetting
    @ObservedObject private var account = AccountService.shared
    @State private var paywall: PremiumFeature?
    /// Classic queue always shows drag handles (as the common streaming apps); Seaglass keeps
    /// reorder behind the list's edit affordance so swipe/play aren't fighting the handles.
    @State private var editMode: EditMode = .inactive

    private var classic: Bool { style == .classic }

    var body: some View {
        List {
            if !classic {
                seaglassControls
            }

            if classic && !macSidePanel {
                classicNowPlayingRow
                classicSectionHeader
            } else if !classic {
                seaglassSectionHeader
            }

            if player.upcoming.isEmpty {
                // A row under the header: laid over the list, it covered the header and Shuffle in
                // the iPhone's short panel.
                ContentUnavailableView(
                    "La coda è vuota", systemImage: "list.bullet",
                    description: Text(player.autoRadio
                        ? "Con la radio automatica arriveranno brani simili."
                        : "Aggiungi brani dal menu ··· di ogni canzone."))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(player.upcoming) { entry in
                // Classic: no ··· — the list's drag handle owns the trailing edge.
                TrackRow(track: entry.track, showsMenu: !classic, queues: false, remove: classic ? nil : {
                    if let offset = player.upcoming.firstIndex(where: { $0.id == entry.id }) {
                        player.removeUpcoming(atOffsets: IndexSet(integer: offset))
                    }
                }) { player.jump(to: entry.index) }
                    .padding(.horizontal, classic ? 0 : 10)
                    .listRowBackground(rowBackground)
                    .listRowSeparator(.hidden)
                    // Classic: the handles only, no red delete buttons, as the common streaming apps.
                    .deleteDisabled(classic)
                    .listRowInsets(EdgeInsets(top: classic ? 4 : 6, leading: classic ? 12 : 0,
                                              bottom: classic ? 4 : 6, trailing: classic ? 4 : 0))
            }
            .onDelete { player.removeUpcoming(atOffsets: $0) }
            .onMove { player.moveUpcoming(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.editMode, classic ? .constant(.active) : $editMode)
        .premiumPaywall($paywall)
        .onAppear {
            // Handles must be visible as soon as the classic queue opens.
            if classic { editMode = .active }
        }
    }

    private var rowBackground: some View {
        Group {
            if classic {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .padding(.vertical, 3)
            }
        }
    }

    @ViewBuilder private var classicNowPlayingRow: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 48, cornerRadius: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ClassicPalette.accent)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(ClassicPalette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { player.togglePlayPause() } label: {
                    // White with a black symbol in the dark, black with a white one in the light.
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 40, height: 40)
                        .background(Color.primary, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? Text("Pausa") : Text("Riproduci"))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("In riproduzione"))
        }
    }

    private var classicSectionHeader: some View {
        Label {
            Text(player.shuffleEnabled ? "Riproduzione casuale da:" : "Prossimi brani")
        } icon: {
            if player.shuffleEnabled { Image(systemName: "shuffle") }
        }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ClassicPalette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
    }

    private var seaglassSectionHeader: some View {
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
    }

    private var seaglassControls: some View {
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
                    BetaBadge()
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
