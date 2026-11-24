import SwiftUI

/// What "Ordina per il mix" shows: the playlist's songs analysed by AutoMix (those with a file on the
/// device: downloaded, or the user's own), the order suggested, and the passages between them.
@MainActor
final class MixOrderModel: ObservableObject {
    enum Status: Equatable {
        case waiting
        /// No file on the device: not downloaded (and not a song of the user's own).
        case notOnDevice
        case analysed
        /// The file couldn't be analysed (unreadable, too long, no sound).
        case failed
    }

    struct Song: Identifiable {
        /// The song's place in the playlist.
        let position: Int
        let track: Track
        var file: URL?
        var status: Status = .waiting
        var analysis: TrackAnalysis?
        var features: MixFeatures?
        var id: Int { position }
    }

    let playlistID: UUID
    let name: String
    @Published private(set) var songs: [Song]
    @Published var mode: MixOrderMode = .smooth {
        didSet { if mode != oldValue { refresh() } }
    }
    @Published private(set) var suggestion = MixOrder.Result(placed: [], unplaced: [])
    @Published private(set) var analysed = 0
    @Published private(set) var isAnalysing = false
    /// The passage being made, and the ones that couldn't be.
    @Published private(set) var preparing: String?
    @Published private(set) var failedPassages: Set<String> = []
    /// The passages heard as the player would mix them (AutoMix, Premium), or one song after the other.
    let mixes: Bool
    let player = PassagePlayer()
    private var clips: [String: TransitionClip] = [:]
    private var task: Task<Void, Never>?
    private var passageTask: Task<Void, Never>?
    private let folder = Storage.caches.appending(path: "MixOrder-\(UUID().uuidString)", directoryHint: .isDirectory)

    init(playlist: Playlist) {
        playlistID = playlist.id
        name = playlist.name
        mixes = AccountService.shared.unlocks(.autoMix)
        songs = playlist.tracks.enumerated().map { position, track in
            let resolved = Library.shared.resolvedTrack(matching: track) ?? track
            return Song(position: position, track: track, file: Storage.localAudio(for: resolved))
        }
        for index in songs.indices where songs[index].file == nil { songs[index].status = .notOnDevice }
        refresh()
    }

    /// Analyses the songs with a file, one at a time (each file once: AutoMix keeps its analyses).
    func start() {
        guard task == nil else { return }
        isAnalysing = true
        task = Task {
            for index in songs.indices {
                guard !Task.isCancelled else { return }
                guard let file = songs[index].file, songs[index].status == .waiting else { continue }
                var analysis: TrackAnalysis?
                if (songs[index].track.duration ?? 0) <= AutoMixLibrary.lengthLimit {
                    // Without the beat model: the order needs the tempo, the key and the energy, and the
                    // model's beats are added later, if a mix needs them.
                    analysis = await AutoMixLibrary.shared.analysis(of: file, priority: .utility, beats: false)
                }
                guard !Task.isCancelled else { return }
                songs[index].analysis = analysis
                songs[index].features = analysis.map { MixFeatures($0) }
                songs[index].status = analysis == nil ? .failed : .analysed
                analysed += 1
                refresh()
            }
            isAnalysing = false
            if LaunchScene.isActive { print("mix-order: analysed \(songs.filter { $0.status == .analysed }.count) of \(songs.count)") }
        }
    }

    var toAnalyse: Int { songs.filter { $0.file != nil }.count }

    private func refresh() {
        let items = songs.map { MixOrder.Item(position: $0.position, features: $0.features) }
        suggestion = MixOrder.suggest(items, mode: mode)
    }

    private var features: [Int: MixFeatures] {
        Dictionary(uniqueKeysWithValues: songs.compactMap { song in song.features.map { (song.position, $0) } })
    }

    func summary(of order: [Int]) -> MixOrder.Summary { MixOrder.summary(of: order, features: features) }
    var originalOrder: [Int] { songs.map(\.position) }

    /// Energy from 1 to 5 within this playlist (its quietest song 1, its loudest 5).
    func energyLevel(of song: Song) -> Int? {
        guard let energy = song.features?.energy else { return nil }
        let all = songs.compactMap { $0.features?.energy }
        guard let low = all.min(), let high = all.max(), high - low > 0.5 else { return 3 }
        return 1 + Int(((energy - low) / (high - low) * 4).rounded())
    }

    // MARK: Passages

    static func key(_ a: Int, _ b: Int) -> String { "\(a)>\(b)" }

    func canPlay(from a: Int, to b: Int) -> Bool {
        songs.indices.contains(a) && songs.indices.contains(b) && songs[a].analysis != nil && songs[b].analysis != nil
            && songs[a].file != nil && songs[b].file != nil
    }

    func togglePassage(from a: Int, to b: Int) {
        let key = Self.key(a, b)
        if player.playing == key { return player.stop() }
        if let clip = clips[key] { return player.play(clip, key: key) }
        guard canPlay(from: a, to: b), let fileA = songs[a].file, let fileB = songs[b].file,
              let analysisA = songs[a].analysis, let analysisB = songs[b].analysis else { return }
        passageTask?.cancel()
        preparing = key
        let mixes = self.mixes
        let folder = self.folder
        passageTask = Task {
            let clip: TransitionClip? = await Task.detached(priority: .userInitiated) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let gains = MixOrder.passageGains(analysisA, analysisB)
                let destination = folder.appending(path: "\(UUID().uuidString).caf")
                if mixes {
                    // With the beat model where it is bundled, as the player plans its mixes.
                    async let fullA = AutoMixLibrary.shared.analysis(of: fileA, priority: .userInitiated)
                    async let fullB = AutoMixLibrary.shared.analysis(of: fileB, priority: .userInitiated)
                    let outgoing = await fullA ?? analysisA, incoming = await fullB ?? analysisB
                    let decision = SeguePolicy.decide(.withListenerSettings(outgoing, incoming, earliestExit: 0))
                    if let plan = decision.plan, decision.level != .normal,
                       let clip = try? await TransitionClipMaker.autoMix(plan, outgoing: fileA, incoming: fileB, gains: gains,
                                                                         to: destination) {
                        return clip
                    }
                }
                return try? await TransitionClipMaker.plain(outgoing: fileA, incoming: fileB, gains: gains, to: destination)
            }.value
            guard !Task.isCancelled else { return }
            preparing = nil
            if let clip {
                clips[key] = clip
                player.play(clip, key: key)
            } else {
                failedPassages.insert(key)
            }
            if LaunchScene.isActive { print("mix-order: passage \(key) \(clip.map { String(format: "%.1f s", $0.length) } ?? "failed")") }
        }
    }

    // MARK: Saving

    /// A new playlist in the suggested order with every song of this one (those that couldn't be
    /// placed at its end), beside it: this one stays as it is.
    @discardableResult
    func save(named title: String) -> Playlist? {
        guard let playlist = Library.shared.playlist(playlistID) else { return nil }
        let tracks = suggestion.order.compactMap { playlist.tracks.indices.contains($0) ? playlist.tracks[$0] : nil }
        guard tracks.count == playlist.tracks.count else { return nil }
        return Library.shared.createPlaylist(named: title, tracks: tracks)
    }

    func close() {
        task?.cancel()
        passageTask?.cancel()
        player.close()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// "Ordina per il mix": a playlist's songs in another order, for mixing (Fluido) or for a build-up
/// (Energia crescente), saved as a new playlist.
struct MixOrderView: View {
    @StateObject private var model: MixOrderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.interfaceStyle) private var style
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @State private var saved: String?

    init(playlist: Playlist) {
        _model = StateObject(wrappedValue: MixOrderModel(playlist: playlist))
    }

    private var classic: Bool { style == .classic }
    private var tint: Color { classic ? ClassicPalette.accent : accent.color }
    private var secondary: Color { classic ? ClassicPalette.secondaryText : .secondary }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Ordine", selection: $model.mode) {
                        Text("Fluido").tag(MixOrderMode.smooth)
                        Text("Energia crescente").tag(MixOrderMode.rising)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    Text(model.mode == .smooth
                         ? "Brani vicini per tempo, tonalità ed energia: ogni passaggio il più morbido possibile."
                         : "Dal brano più calmo al più energico, misurati dall'analisi di AutoMix.")
                        .font(.footnote)
                        .foregroundStyle(secondary)
                        .listRowBackground(Color.clear)
                    summaryCard
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                }
                .listRowSeparator(.hidden)

                Section {
                    let placed = model.suggestion.placed
                    ForEach(Array(placed.enumerated()), id: \.element) { offset, position in
                        songRow(number: offset + 1, model.songs[position])
                        if offset + 1 < placed.count {
                            passageRow(from: position, to: placed[offset + 1])
                        }
                    }
                } header: {
                    Text("Ordine suggerito")
                }
                .classicRows(classic)
                .listRowBackground(classic ? Color.clear : nil)

                if !model.suggestion.unplaced.isEmpty {
                    Section {
                        ForEach(model.suggestion.unplaced, id: \.self) { position in
                            songRow(number: nil, model.songs[position])
                        }
                    } header: {
                        Text("Senza analisi")
                    } footer: {
                        Text("Questi brani non sono sul dispositivo o non si possono analizzare: restano in fondo, nell'ordine della playlist, e nessun valore viene inventato. Scaricali per includerli.")
                    }
                    .classicRows(classic)
                    .listRowBackground(classic ? Color.clear : nil)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background {
                if classic { ClassicPalette.background.ignoresSafeArea() } else { BrowseBackground() }
            }
            .safeAreaInset(edge: .bottom) { saveBar }
            .navigationTitle("Ordina per il mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .animation(.smooth(duration: 0.3), value: model.suggestion)
        }
        .tint(tint)
        .onAppear { model.start() }
        .onDisappear { model.close() }
    }

    // MARK: Summary

    private var summaryCard: some View {
        let after = model.summary(of: model.suggestion.order)
        let before = model.summary(of: model.originalOrder)
        return VStack(alignment: .leading, spacing: 8) {
            if model.isAnalysing {
                ProgressView(value: Double(model.analysed), total: Double(max(1, model.toAnalyse))) {
                    Text("Analisi dei brani sul dispositivo: \(model.analysed) di \(model.toAnalyse)")
                        .font(.subheadline)
                }
            } else {
                Label("Analizzati \(model.songs.filter { $0.status == .analysed }.count) brani di \(model.songs.count)",
                      systemImage: "waveform.badge.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
            }
            if after.tempoPairs > 0 {
                Text("Passaggi a tempo: \(after.tempoClose) di \(after.tempoPairs) (prima \(before.tempoClose))")
                    .font(.footnote)
                    .foregroundStyle(secondary)
            }
            if after.keyPairs > 0 {
                Text("Passaggi in tonalità: \(after.keysMatch) di \(after.keyPairs) (prima \(before.keysMatch))")
                    .font(.footnote)
                    .foregroundStyle(secondary)
            }
            if !model.mixes {
                Text("Senza Premium i passaggi si ascoltano un brano dopo l'altro; con AutoMix li senti mixati.")
                    .font(.footnote)
                    .foregroundStyle(secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .styledSurface(in: .rect(cornerRadius: 18))
    }

    // MARK: Rows

    private func songRow(number: Int?, _ song: MixOrderModel.Song) -> some View {
        HStack(spacing: 12) {
            Text(number.map { "\($0)" } ?? "–")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(secondary)
                .monospacedDigit()
                .frame(minWidth: 22)
            ArtworkView(track: song.track, size: 44, cornerRadius: classic ? 4 : 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.track.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(song.track.artist)
                    .font(.caption)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            badges(song)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func badges(_ song: MixOrderModel.Song) -> some View {
        switch song.status {
        case .waiting:
            ProgressView().controlSize(.small)
        case .notOnDevice:
            Text("Non scaricato").font(.caption).foregroundStyle(secondary)
        case .failed:
            Text("Analisi non riuscita").font(.caption).foregroundStyle(.orange)
        case .analysed:
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    if let tempo = song.features?.tempo {
                        Text("\(Int(tempo.rounded())) BPM")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    } else {
                        Text("Tempo incerto").font(.caption).foregroundStyle(secondary)
                    }
                    if let code = song.features?.camelotCode {
                        Text(code)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.1), in: .rect(cornerRadius: 5))
                    }
                }
                if song.features?.camelot == nil {
                    Text("Tonalità incerta").font(.caption2).foregroundStyle(secondary)
                } else if let level = model.energyLevel(of: song) {
                    Image(systemName: "cellularbars", variableValue: Double(level) / 5)
                        .font(.caption)
                        .foregroundStyle(tint)
                        .accessibilityLabel(Text("Energia \(level) su 5"))
                }
            }
        }
    }

    @ViewBuilder private func passageRow(from a: Int, to b: Int) -> some View {
        let key = MixOrderModel.key(a, b)
        if model.canPlay(from: a, to: b) {
            let playing = model.player.playing == key
            Button { model.togglePassage(from: a, to: b) } label: {
                HStack(spacing: 10) {
                    Group {
                        if model.preparing == key {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(tint)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 26)
                    Text(passageLabel(key, playing: playing))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(playing ? tint : secondary)
                    Spacer(minLength: 0)
                    fit(from: a, to: b)
                }
                .padding(.leading, 34)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.failedPassages.contains(key))
        }
    }

    private func passageLabel(_ key: String, playing: Bool) -> LocalizedStringKey {
        if model.failedPassages.contains(key) { return "Passaggio non disponibile" }
        if model.preparing == key { return "Preparazione del passaggio…" }
        return playing ? "In ascolto del passaggio" : "Ascolta il passaggio"
    }

    /// How the two songs go together, from what is known of both.
    @ViewBuilder private func fit(from a: Int, to b: Int) -> some View {
        if let fa = model.songs[a].features, let fb = model.songs[b].features {
            HStack(spacing: 6) {
                if MixOrder.tempoClose(fa, fb) == true {
                    Image(systemName: "metronome").accessibilityLabel(Text("A tempo"))
                }
                if MixOrder.keysMatch(fa, fb) == true {
                    Image(systemName: "music.note").accessibilityLabel(Text("In tonalità"))
                }
            }
            .font(.caption)
            .foregroundStyle(secondary)
        }
    }

    // MARK: Saving

    private var saveBar: some View {
        VStack(spacing: 8) {
            if let saved {
                Label("Salvata come «\(saved)»", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
                    .transition(.opacity)
            }
            Button {
                let mode = model.mode == .smooth ? String(localized: "Fluido") : String(localized: "Energia crescente")
                let title = "\(model.name) · \(mode)"
                if let playlist = model.save(named: title) {
                    withAnimation { saved = playlist.name }
                    if LaunchScene.isActive { print("mix-order: saved \(playlist.name) with \(playlist.tracks.count) songs") }
                }
            } label: {
                Text("Salva come nuova playlist")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .styledButton(prominent: true)
            .controlSize(.large)
            .disabled(model.isAnalysing || model.songs.isEmpty)
            Text("La playlist originale resta com'è; la nuova ha tutti i suoi brani.")
                .font(.caption)
                .foregroundStyle(secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            if classic { ClassicPalette.background.opacity(0.95).ignoresSafeArea() }
        }
    }
}
