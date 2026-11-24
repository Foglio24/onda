import SwiftUI

/// What the AutoMix demo's page shows and plays (see `AutoMixDemo`).
@MainActor
final class AutoMixDemoModel: ObservableObject {
    enum Version: String, CaseIterable, Identifiable {
        case plain, autoMix
        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case preparing(String)
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .preparing(String(localized: "Preparazione della demo…"))
    @Published private(set) var prepared: AutoMixDemo.Prepared?
    let player = PassagePlayer()
    private var task: Task<Void, Never>?

    /// The page open, for CI's scene that plays it over a queue (see `LaunchScene`).
    static weak var shown: AutoMixDemoModel?

    func prepare() {
        Self.shown = self
        guard task == nil, prepared == nil else { return }
        phase = .preparing(String(localized: "Preparazione della demo…"))
        task = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await AutoMixDemo.prepare { [weak self] step in await self?.show(step: step) }
                }.value
                prepared = result
                phase = .ready
                if LaunchScene.isActive {
                    print(String(format: "automix-demo: ready, plain %.1f s (passage %.1f–%.1f s), automix %.1f s (passage %.1f–%.1f s), %@%@",
                                 result.plain.length, result.plain.passageStart, result.plain.passageEnd,
                                 result.autoMix.length, result.autoMix.passageStart, result.autoMix.passageEnd,
                                 result.plan.level.rawValue, result.usedDefaults ? ", defaults" : ""))
                }
            } catch is CancellationError {
            } catch {
                phase = .failed(error.localizedDescription)
                if LaunchScene.isActive { print("automix-demo: failed \(error)") }
            }
            task = nil
        }
    }

    private func show(step: String) {
        if case .preparing = phase { phase = .preparing(step) }
    }

    func clip(_ version: Version) -> TransitionClip? {
        switch version {
        case .plain: return prepared?.plain
        case .autoMix: return prepared?.autoMix
        }
    }

    func toggle(_ version: Version) {
        guard let clip = clip(version) else { return }
        player.toggle(clip, key: version.rawValue)
    }

    func retry() {
        task?.cancel()
        task = nil
        prepared = nil
        prepare()
    }

    /// The page closes: what was playing before it plays on (see `PassagePlayer.close`).
    func close() {
        task?.cancel()
        task = nil
        player.close()
        if Self.shown === self { Self.shown = nil }
    }
}

/// The Home's AutoMix demo: the same two songs, one after the other and then mixed by AutoMix.
struct AutoMixDemoView: View {
    @StateObject private var model = AutoMixDemoModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.interfaceStyle) private var style
    @EnvironmentObject private var account: AccountService
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    private var tint: Color { style == .classic ? ClassicPalette.accent : accent.color }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Ascolta due volte la stessa coppia di brani: prima uno dopo l'altro, poi con AutoMix. Stessi brani, stesso volume: cambia solo il passaggio.")
                        .font(.body)
                        .foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    songs
                    switch model.phase {
                    case .preparing(let step):
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(step)
                                .font(.subheadline)
                                .foregroundStyle(secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .styledSurface(in: .rect(cornerRadius: 22))
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 12) {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                            Button("Riprova") { model.retry() }
                                .styledButton()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .styledSurface(in: .rect(cornerRadius: 22))
                    case .ready:
                        ForEach(AutoMixDemoModel.Version.allCases) { version in
                            versionCard(version)
                        }
                    }
                    footnotes
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .animation(.smooth(duration: 0.3), value: model.phase)
            }
            .background {
                if style == .classic { ClassicPalette.background.ignoresSafeArea() } else { BrowseBackground() }
            }
            .navigationTitle("Prova AutoMix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
        .tint(tint)
        .onAppear { model.prepare() }
        .onDisappear { model.close() }
    }

    private var primary: Color { style == .classic ? ClassicPalette.primaryText : .primary }
    private var secondary: Color { style == .classic ? ClassicPalette.secondaryText : .secondary }

    // MARK: The two songs

    private var songs: some View {
        HStack(spacing: 10) {
            song(0)
            Image(systemName: "arrow.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(secondary)
                .accessibilityHidden(true)
            song(1)
        }
    }

    private func song(_ index: Int) -> some View {
        let demo = AutoMixDemo.songs[index]
        let analyses = model.prepared?.analyses ?? []
        let analysis = analyses.indices.contains(index) ? analyses[index] : nil
        return VStack(alignment: .leading, spacing: 4) {
            Text(demo.title)
                .font(.headline)
                .foregroundStyle(primary)
                .lineLimit(1)
            // Only what the analysis measured: nothing before it, and no key it isn't sure of.
            if let analysis {
                Text(Self.measured(analysis))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Text(AutoMixDemo.artist)
                    .font(.caption)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .styledSurface(in: .rect(cornerRadius: 16))
    }

    static func measured(_ analysis: TrackAnalysis) -> String {
        var parts: [String] = []
        if let tempo = analysis.shownTempo { parts.append("\(Int(tempo.rounded())) BPM") }
        if analysis.hasClearKey { parts.append(Camelot.code(key: analysis.key, minor: analysis.minor)) }
        return parts.isEmpty ? AutoMixDemo.artist : parts.joined(separator: " · ")
    }

    // MARK: The two listens

    private func versionCard(_ version: AutoMixDemoModel.Version) -> some View {
        let clip = model.clip(version)
        let playing = model.player.playing == version.rawValue
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(version == .plain ? "Passaggio normale" : "Con AutoMix")
                        .font(.headline)
                        .foregroundStyle(primary)
                    Text(subtitle(version))
                        .font(.subheadline)
                        .foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                playButton(playing: playing, title: version == .plain ? "Passaggio normale" : "Con AutoMix") {
                    model.toggle(version)
                }
            }
            if let clip {
                PassageBar(clip: clip, position: playing ? model.player.position : nil, tint: tint)
                Text(status(clip, playing: playing))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(playing ? tint : secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .padding(16)
        .styledSurface(in: .rect(cornerRadius: 22))
    }

    private func subtitle(_ version: AutoMixDemoModel.Version) -> String {
        switch version {
        case .plain:
            return String(localized: "Un brano dopo l'altro, come senza transizioni")
        case .autoMix:
            guard let plan = model.prepared?.plan else { return String(localized: "Il mix che AutoMix prepara per questi brani") }
            return PlayerController.describe(plan)
        }
    }

    private func status(_ clip: TransitionClip, playing: Bool) -> String {
        guard playing else {
            return String(localized: "Durata \(clip.length.formattedTime) · il passaggio a \(clip.passageStart.formattedTime)")
        }
        let position = model.player.position
        if position < clip.passageStart {
            return String(localized: "Il passaggio inizia tra \(Int((clip.passageStart - position).rounded(.up))) s")
        }
        if position <= max(clip.passageEnd, clip.passageStart + 1) { return String(localized: "Passaggio in corso") }
        return String(localized: "Ora suona \(AutoMixDemo.songs[1].title)")
    }

    @ViewBuilder
    private func playButton(playing: Bool, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        let symbol = playing ? "stop.fill" : "play.fill"
        if style == .classic {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(ClassicPalette.accent, in: .circle)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? Text("Ferma") : Text("Ascolta: \(Text(title))"))
        } else {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(playing ? Text("Ferma") : Text("Ascolta: \(Text(title))"))
        }
    }

    // MARK: Notes

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("I brani demo sono creati sul dispositivo: la prova funziona senza account, senza Premium e offline, e non entra nella cronologia.",
                  systemImage: "checkmark.seal")
            if model.player.resumesQueue {
                Label("Quello che stavi ascoltando è in pausa e riprende da dove era quando chiudi.", systemImage: "pause.circle")
            }
            if model.prepared?.usedDefaults == true {
                Label("Con le tue impostazioni di AutoMix questi brani non si mixano: la demo usa quelle predefinite.",
                      systemImage: "slider.horizontal.3")
            }
            if !account.unlocks(.autoMix) {
                Label("AutoMix sui tuoi brani fa parte di Premium: la prova gratuita vale solo per i brani demo.", systemImage: "sparkles")
            }
        }
        .font(.footnote)
        .foregroundStyle(secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A listen's length, its passage (shaded) and, while it plays, how far it has got.
struct PassageBar: View {
    let clip: TransitionClip
    let position: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = { (time: Double) -> CGFloat in CGFloat(max(0, min(1, time / max(clip.length, 0.1)))) * width }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Rectangle()
                    .fill(tint.opacity(0.35))
                    .frame(width: max(4, x(clip.passageEnd) - x(clip.passageStart)))
                    .offset(x: x(clip.passageStart))
                if let position {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(8, x(position)))
                        .animation(.linear(duration: 0.1), value: position)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// The Home's way into the demo: a card in both styles (glass in Seaglass's, flat in the classic one).
struct AutoMixDemoCard: View {
    @Environment(\.interfaceStyle) private var style
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink

    var body: some View {
        let classic = style == .classic
        Button { AppRouter.shared.showAutoMixDemo = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "wand.and.rays")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(classic ? Color.black : Color.white)
                    .frame(width: 52, height: 52)
                    .background(classic ? AnyShapeStyle(ClassicPalette.accent) : AnyShapeStyle(accent.color.gradient),
                                in: .rect(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prova AutoMix")
                        .font(.headline)
                        .foregroundStyle(classic ? ClassicPalette.primaryText : .primary)
                    Text("Lo stesso passaggio, normale e mixato. Anche offline.")
                        .font(.subheadline)
                        .foregroundStyle(classic ? ClassicPalette.secondaryText : .secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(classic ? ClassicPalette.secondaryText : .secondary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .contentShape(.rect(cornerRadius: 22))
            .styledSurface(in: .rect(cornerRadius: 22), interactive: true)
        }
        .buttonStyle(.browsePress)
        .accessibilityIdentifier("home.automixDemo")
    }
}
