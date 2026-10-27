import AVFoundation
import SwiftUI

/// The five parts of a transition the Mix editor lets you choose, as in Spotify's Mix.
enum MixCategory: Int, CaseIterable, Identifiable {
    case volume, eq, filter, effects, loop

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .volume: return String(localized: "Volume")
        case .eq: return String(localized: "EQ")
        case .filter: return String(localized: "Filtra")
        case .effects: return String(localized: "Effetti")
        case .loop: return String(localized: "Looping")
        }
    }

    var color: Color {
        switch self {
        case .volume: return Color(red: 0.42, green: 0.71, blue: 0.93)
        case .eq: return Color(red: 0.96, green: 0.78, blue: 0.26)
        case .filter: return Color(red: 0.88, green: 0.55, blue: 0.96)
        case .effects: return .white
        case .loop: return Color(red: 0.97, green: 0.62, blue: 0.22)
        }
    }

    func value(_ design: MixDesign) -> String {
        switch self {
        case .volume: return design.volume.title
        case .eq: return design.eq.title
        case .filter: return design.filter.title
        case .effects: return design.effect.title
        case .loop: return design.loop.title
        }
    }
}

/// What opens the Mix at launch (`LaunchScene`), or from anywhere through `AppRouter`.
struct MixTarget: Identifiable {
    let id = UUID()
    let playlistID: UUID
    var opensFirst = false
    var options: MixCategory?
}

// MARK: Playlist

/// A playlist's Mix: on or off, and the transition between each pair of songs, each opened in
/// `TransitionEditorView`. Only for downloaded playlists: the songs are analysed and mixed from
/// their files, with no data used.
struct PlaylistMixView: View {
    let playlistID: UUID
    var opensFirst = false
    var opensOptions: MixCategory?

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Int] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let playlist = library.playlist(playlistID) {
                    content(playlist)
                } else {
                    ContentUnavailableView("Playlist eliminata", systemImage: "music.note.list")
                }
            }
            .background { AmbientBackground() }
            .navigationTitle("Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .navigationDestination(for: Int.self) { index in
                if let playlist = library.playlist(playlistID), index + 1 < playlist.tracks.count {
                    TransitionEditorView(playlistID: playlistID, from: playlist.tracks[index],
                                         to: playlist.tracks[index + 1], opensOptions: opensOptions)
                }
            }
        }
        .onAppear {
            if opensFirst, path.isEmpty { path = [0] }
        }
    }

    private func content(_ playlist: Playlist) -> some View {
        let downloaded = !playlist.tracks.isEmpty && playlist.tracks.allSatisfy { downloads.isDownloaded($0) }
        let enabled = Binding {
            playlist.mix?.enabled ?? false
        } set: { isOn in
            library.setMixEnabled(isOn, for: playlistID)
            PlayerController.shared.applyTransitionPreference()
        }
        return List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: enabled) {
                        Label("Mix attivo", systemImage: "slider.horizontal.3")
                            .font(.headline)
                    }
                    .disabled(!downloaded)
                    Text("Le transizioni tra i brani della playlist come le scegli tu: preset, volume, EQ, filtri, effetti e loop. Suonano quando ascolti la playlist; dove non cambi nulla decide AutoMix.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }

            if !downloaded {
                Section {
                    VStack(spacing: 12) {
                        Text("Il Mix funziona con le playlist scaricate: i brani vengono analizzati e mixati dai loro file, senza usare dati.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        CollectionDownloadButton(tracks: playlist.tracks,
                                                 downloadTitle: String(localized: "Scarica tutta la playlist"),
                                                 doneTitle: String(localized: "Playlist scaricata"), verticalPadding: 11)
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }

            Section("Transizioni") {
                ForEach(0..<max(0, playlist.tracks.count - 1), id: \.self) { index in
                    let from = playlist.tracks[index], to = playlist.tracks[index + 1]
                    let design = playlist.mix?.transitions[PlaylistMix.key(from: from.id, to: to.id)]
                    NavigationLink(value: index) {
                        TransitionRow(from: from, to: to, preset: design?.preset ?? .auto)
                    }
                    .disabled(!downloaded)
                    .listRowBackground(Color.white.opacity(0.06))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

private struct TransitionRow: View {
    let from: Track
    let to: Track
    let preset: MixPreset

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(track: from, size: 38, cornerRadius: 7)
                    .offset(x: -10, y: -8)
                ArtworkView(track: to, size: 38, cornerRadius: 7)
                    .shadow(color: .black.opacity(0.4), radius: 4)
            }
            .frame(width: 52, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(from.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Label(to.title, systemImage: "arrow.turn.down.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(preset.title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
        }
    }
}

// MARK: Transition

/// One transition of the Mix, as Spotify's editor: both songs' waveforms overlapping with the
/// volume, bass and filter curves over them (drag them to move and lengthen the mix), the presets,
/// the five parts, beatmatching, and a preview of the mix.
struct TransitionEditorView: View {
    let playlistID: UUID
    let from: Track
    let to: Track
    var opensOptions: MixCategory?

    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = MixPreview()
    @State private var design = MixDesign()
    @State private var analyses: (outgoing: TrackAnalysis, incoming: TrackAnalysis)?
    @State private var waves: (outgoing: MixWaveform, incoming: MixWaveform)?
    @State private var failed = false
    @State private var options: MixCategory?
    @State private var dragStart: (overlap: Double, shift: Double)?

    private var plan: TransitionPlan? {
        analyses.map { MixDesigner.plan(from: $0.outgoing, to: $0.incoming, design: design) }
    }

    private var canBeatmatch: Bool {
        analyses.map { MixDesigner.canBeatmatch($0.outgoing, $0.incoming) } ?? false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header(from, analysis: analyses?.outgoing)
                waveformBox
                header(to, analysis: analyses?.incoming)
                if failed {
                    Text("Non è stato possibile analizzare questi brani.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                presets
                categories
                beatmatchRow
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background { AmbientBackground() }
        .navigationTitle("Transizione")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Salva") { save() }
                    .disabled(analyses == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { design = MixDesign(beatmatch: canBeatmatch) } label: {
                        Label("Torna ad Auto", systemImage: "sparkles")
                    }
                    Button(role: .destructive) {
                        library.setMixDesign(nil, from: from, to: to, in: playlistID)
                        PlayerController.shared.applyTransitionPreference()
                        dismiss()
                    } label: {
                        Label("Rimuovi la transizione", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .task { await load() }
        .onDisappear { preview.stop() }
        .sheet(item: $options) { category in
            MixOptionsSheet(design: $design, start: category)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Parts

    private func header(_ track: Track, analysis: TrackAnalysis?) -> some View {
        HStack(spacing: 12) {
            ArtworkView(track: track, size: 54, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let analysis {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        if !canBeatmatch {
                            Image(systemName: "exclamationmark.circle.fill")
                        }
                        Text("\(Int(analysis.tempo.rounded())) BPM")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(canBeatmatch ? Color.primary : Color.orange)
                    HStack(spacing: 6) {
                        Text(Camelot.code(key: analysis.key, minor: analysis.minor))
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.18), in: .rect(cornerRadius: 5))
                        Text(Self.time(analysis.duration))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var waveformBox: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let box = Self.box(in: size)
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .frame(width: box.width, height: size.height)
                    .position(x: box.midX, y: size.height / 2)
                if let plan, let waves {
                    Canvas { context, canvasSize in
                        MixDrawing.draw(in: &context, size: canvasSize, box: Self.box(in: canvasSize), plan: plan,
                                        outgoing: waves.outgoing, incoming: waves.incoming,
                                        playhead: preview.position)
                    }
                    .allowsHitTesting(false)
                } else if !failed {
                    ProgressView()
                }
                Button { togglePreview() } label: {
                    Image(systemName: preview.isPlaying ? "stop.fill" : (preview.isPreparing ? "hourglass" : "play.fill"))
                        .font(.title3)
                        .frame(width: 58, height: 42)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .position(x: size.width / 2, y: size.height / 2)
                .disabled(plan == nil)
            }
            .contentShape(Rectangle())
            .gesture(drag(size: size))
        }
        .frame(height: 330)
    }

    private var presets: some View {
        VStack(spacing: 10) {
            HStack {
                Rectangle().fill(.secondary.opacity(0.4)).frame(height: 1)
                Text("Preset")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Rectangle().fill(.secondary.opacity(0.4)).frame(height: 1)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(MixPreset.choices, id: \.self) { preset in
                        let selected = design.preset == preset
                        Button { apply(preset) } label: {
                            Label {
                                Text(preset.title)
                            } icon: {
                                if preset == .auto { Image(systemName: "sparkles") }
                            }
                            .font(.headline)
                            .foregroundStyle(selected ? Color.black : Color.primary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(selected ? Glass.regular.tint(.white).interactive() : Glass.regular.interactive(), in: .capsule)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var categories: some View {
        VStack(spacing: 0) {
            ForEach(MixCategory.allCases) { category in
                Button { options = category } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(category.color)
                            .frame(width: 4, height: 22)
                        Text(category.title)
                            .font(.headline)
                        Spacer(minLength: 12)
                        Text(category.value(design))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if category != MixCategory.allCases.last {
                    Divider().padding(.leading, 32)
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var beatmatchRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Beatmatching")
                    .font(.headline)
                Text(canBeatmatch ? String(localized: "I battiti dei due brani vanno a tempo")
                                  : String(localized: "Beatmatch non disponibile"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Beatmatching", isOn: $design.beatmatch)
                .labelsHidden()
                .disabled(!canBeatmatch)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .opacity(analyses == nil ? 0.5 : 1)
    }

    // MARK: Actions

    private func apply(_ preset: MixPreset) {
        var next = MixDesign.preset(preset)
        next.beatmatch = design.beatmatch
        next.overlap = design.overlap
        next.shift = design.shift
        design = next
    }

    /// Dragging the lower song moves where it comes in (the overlap gets longer or shorter);
    /// dragging the upper one moves where the song leaving ends. In whole bars with beatmatching.
    private func drag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard let plan else { return }
                let box = Self.box(in: size)
                let secondsPerPoint = plan.overlap / Double(max(1, box.width))
                if dragStart == nil { dragStart = (plan.overlap, design.shift) }
                guard let start = dragStart else { return }
                let moved = Double(value.translation.width) * secondsPerPoint
                let step = design.beatmatch && canBeatmatch ? plan.barLength : 0.5
                if value.startLocation.y > size.height / 2 {
                    let overlap = max(step, min(64, start.overlap - moved))
                    design.overlap = (overlap / step).rounded() * step
                } else {
                    design.shift = ((start.shift - moved) / step).rounded() * step
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    private func togglePreview() {
        guard let plan, let fileA = Self.file(for: from), let fileB = Self.file(for: to) else { return }
        preview.toggle(plan: plan, outgoing: fileA, incoming: fileB)
    }

    private func save() {
        library.setMixDesign(design, from: from, to: to, in: playlistID)
        if library.playlist(playlistID)?.mix?.enabled == false { library.setMixEnabled(true, for: playlistID) }
        PlayerController.shared.applyTransitionPreference()
        dismiss()
    }

    private func load() async {
        guard analyses == nil else { return }
        if let saved = library.playlist(playlistID)?.mix?.transitions[PlaylistMix.key(from: from.id, to: to.id)] {
            design = saved
        }
        guard let fileA = Self.file(for: from), let fileB = Self.file(for: to) else {
            failed = true
            return
        }
        async let outgoing = AutoMixLibrary.shared.analysis(of: fileA)
        async let incoming = AutoMixLibrary.shared.analysis(of: fileB)
        guard let analysisA = await outgoing, let analysisB = await incoming else {
            failed = true
            return
        }
        if library.playlist(playlistID)?.mix?.transitions[PlaylistMix.key(from: from.id, to: to.id)] == nil {
            design.beatmatch = MixDesigner.canBeatmatch(analysisA, analysisB)
        }
        analyses = (analysisA, analysisB)
        async let waveA = MixWaveform.make(file: fileA, from: max(0, analysisA.duration - 110), to: analysisA.duration)
        async let waveB = MixWaveform.make(file: fileB, from: 0, to: min(analysisB.duration, 110))
        if let a = await waveA, let b = await waveB { waves = (a, b) }
        if let opensOptions { options = opensOptions }
    }

    static func file(for track: Track) -> URL? {
        Storage.localAudio(for: Library.shared.resolvedTrack(matching: track) ?? track)
    }

    /// The rounded box stands for the overlap; the songs before and after spill out of it.
    static func box(in size: CGSize) -> CGRect {
        CGRect(x: size.width * 0.13, y: 0, width: size.width * 0.74, height: size.height)
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%ld:%02ld", total / 60, total % 60)
    }
}

// MARK: Options

/// The options of the five parts, one page each (swipe between them), as in Spotify's Mix.
struct MixOptionsSheet: View {
    @Binding var design: MixDesign
    let start: MixCategory
    @State private var page: MixCategory = .volume

    var body: some View {
        TabView(selection: $page) {
            ForEach(MixCategory.allCases) { category in
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(category.color)
                            .frame(width: 4, height: 24)
                        Text(category.title)
                            .font(.title3.weight(.semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    Divider()
                    List {
                        ForEach(rows(for: category), id: \.title) { row in
                            Button(action: row.choose) {
                                HStack {
                                    Text(row.title)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if row.selected {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.bold))
                                            .foregroundStyle(.green)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    // Room for the page dots under the last option.
                    .contentMargins(.bottom, 44, for: .scrollContent)
                }
                .tag(category)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        .presentationBackground(.regularMaterial)
        .onAppear { page = start }
    }

    private struct Row {
        let title: String
        let selected: Bool
        let choose: () -> Void
    }

    private func rows(for category: MixCategory) -> [Row] {
        func custom(_ change: @escaping (inout MixDesign) -> Void) -> () -> Void {
            {
                change(&design)
                design.preset = .custom
            }
        }
        switch category {
        case .volume:
            return MixVolume.allCases.map { option in
                Row(title: option.title, selected: design.volume == option, choose: custom { $0.volume = option })
            }
        case .eq:
            return MixEQ.allCases.map { option in
                Row(title: option.title, selected: design.eq == option, choose: custom { $0.eq = option })
            }
        case .filter:
            return MixFilter.allCases.map { option in
                Row(title: option.title, selected: design.filter == option, choose: custom { $0.filter = option })
            }
        case .effects:
            return MixEffect.allCases.map { option in
                Row(title: option.title, selected: design.effect == option, choose: custom { $0.effect = option })
            }
        case .loop:
            return MixLoop.allCases.map { option in
                Row(title: option.title, selected: design.loop == option, choose: custom { $0.loop = option })
            }
        }
    }
}

// MARK: Waveforms

/// A stretch of a song's waveform for the Mix editor: loudness in 40 ms steps, overall and for the
/// low (bass and kick) and high bands.
struct MixWaveform: Sendable {
    let start: Double
    let step: Double
    let full: [Float]
    let low: [Float]
    let high: [Float]

    static func make(file: URL, from: Double, to: Double) async -> MixWaveform? {
        guard let samples = try? await AutoMixDecoder.samples(of: file) else { return nil }
        let rate = TrackAnalyzer.sampleRate
        let first = max(0, Int(from * rate)), last = min(samples.count, Int(to * rate))
        let window = Int(0.04 * rate)
        guard last - first > window * 4 else { return nil }
        let lowCoefficient = Float(1 - exp(-2 * Double.pi * 200 / rate))
        let highCoefficient = Float(1 - exp(-2 * Double.pi * 3_000 / rate))
        var lowState: Float = 0, midState: Float = 0
        var full: [Float] = [], low: [Float] = [], high: [Float] = []
        var index = first
        while index + window <= last {
            var sumFull: Float = 0, sumLow: Float = 0, sumHigh: Float = 0
            for position in index..<(index + window) {
                let x = samples[position]
                lowState += lowCoefficient * (x - lowState)
                midState += highCoefficient * (x - midState)
                let h = x - midState
                sumFull += x * x
                sumLow += lowState * lowState
                sumHigh += h * h
            }
            full.append((sumFull / Float(window)).squareRoot())
            low.append((sumLow / Float(window)).squareRoot())
            high.append((sumHigh / Float(window)).squareRoot())
            index += window
        }
        let peak = max(full.max() ?? 1, 1e-6)
        return MixWaveform(start: Double(first) / rate, step: Double(window) / rate,
                           full: full.map { $0 / peak }, low: low.map { $0 / peak }, high: high.map { min(1, $0 / peak * 1.6) })
    }

    func index(at time: Double) -> Int? {
        let index = Int((time - start) / step)
        return full.indices.contains(index) ? index : nil
    }
}

/// Draws the editor's waveforms (the song leaving on top, warm colours; the next one below, blue)
/// and the curves of the mix over them, mapped to the song leaving's time.
enum MixDrawing {
    static func draw(in context: inout GraphicsContext, size: CGSize, box: CGRect, plan: TransitionPlan,
                     outgoing: MixWaveform, incoming: MixWaveform, playhead: Double?) {
        let scale = Double(box.width) / max(0.5, plan.overlap)
        let x = { (time: Double) -> CGFloat in box.minX + CGFloat((time - plan.outStart) * scale) }
        // The next song's time in the leaving song's, while they play together.
        let ratio = plan.tempoIn / plan.tempoOut
        let fromIncoming = { (time: Double) -> Double in plan.outStart + (time - plan.inStart) * ratio }
        let topLane = CGRect(x: 0, y: size.height * 0.06, width: size.width, height: size.height * 0.4)
        let bottomLane = CGRect(x: 0, y: size.height * 0.54, width: size.width, height: size.height * 0.4)

        // The song leaving, up to where it has gone.
        let warm = (Color(red: 0.86, green: 0.58, blue: 0.32), Color(red: 0.55, green: 0.33, blue: 0.16),
                    Color(red: 0.97, green: 0.92, blue: 0.82))
        let cool = (Color(red: 0.15, green: 0.24, blue: 0.78), Color(red: 0.55, green: 0.33, blue: 0.16),
                    Color(red: 0.97, green: 0.92, blue: 0.82))
        let barWidth = max(1, CGFloat(outgoing.step * scale) * 0.9)
        var time = plan.outStart - Double(box.minX) / scale
        while time < plan.outEnd {
            if let index = outgoing.index(at: time) {
                bar(&context, at: x(time), lane: topLane, width: barWidth, values: (outgoing.full[index],
                    outgoing.low[index], outgoing.high[index]), colors: warm)
            }
            time += outgoing.step
        }
        var incomingTime = plan.inStart
        let incomingWidth = max(1, CGFloat(incoming.step * scale * ratio) * 0.9)
        while x(fromIncoming(incomingTime)) < size.width {
            if let index = incoming.index(at: incomingTime) {
                bar(&context, at: x(fromIncoming(incomingTime)), lane: bottomLane, width: incomingWidth,
                    values: (incoming.full[index], incoming.low[index], incoming.high[index]), colors: cool)
            }
            incomingTime += incoming.step
        }

        // The curves: volumes (blue), bass (yellow), filters (pink) and effects (white).
        let samples = (0...120).map { Double($0) / 120 }
        func curve(_ lane: CGRect, color: Color, dashed: Bool = false, _ value: (TransitionLevels) -> Float) {
            var path = Path()
            for (position, progress) in samples.enumerated() {
                let level = CGFloat(value(plan.levels(at: progress)))
                let point = CGPoint(x: box.minX + CGFloat(progress) * box.width,
                                    y: lane.maxY - level * lane.height)
                if position == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: dashed ? [6, 5] : []))
        }
        let design = plan.design
        curve(topLane, color: MixCategory.volume.color) { $0.outgoing }
        curve(bottomLane, color: MixCategory.volume.color) { $0.incoming }
        if design?.eq != MixEQ.none {
            curve(topLane, color: MixCategory.eq.color) { 1 - $0.outgoingBassCut }
            curve(bottomLane, color: MixCategory.eq.color) { 1 - $0.incomingBassCut }
        }
        if let design, design.filter != .none {
            curve(topLane, color: MixCategory.filter.color, dashed: true) { 1 - max($0.outgoingLowPass, $0.outgoingHighPass) }
            curve(bottomLane, color: MixCategory.filter.color, dashed: true) { 1 - max($0.incomingLowPass, $0.incomingHighPass) }
        }
        if let design, design.effect != .none {
            curve(topLane, color: MixCategory.effects.color, dashed: true) { max($0.reverb, $0.echo) }
        }
        if let playhead {
            let position = x(playhead)
            var line = Path()
            line.move(to: CGPoint(x: position, y: 0))
            line.addLine(to: CGPoint(x: position, y: size.height))
            context.stroke(line, with: .color(.green), lineWidth: 3)
        }
    }

    private static func bar(_ context: inout GraphicsContext, at x: CGFloat, lane: CGRect, width: CGFloat,
                            values: (Float, Float, Float), colors: (Color, Color, Color)) {
        let middle = lane.midY
        let half = lane.height / 2
        for (value, color, thinner) in [(values.0, colors.0, CGFloat(1)), (values.1, colors.1, 1), (values.2, colors.2, 0.5)] {
            let height = CGFloat(max(0.01, value)) * half
            let rect = CGRect(x: x - width * thinner / 2, y: middle - height, width: max(1, width * thinner), height: height * 2)
            context.fill(Path(rect), with: .color(color))
        }
    }
}

// MARK: Preview

/// Plays the mix being designed: rendered as it would play, from a few seconds before the next song
/// comes in. The player pauses meanwhile.
@MainActor
final class MixPreview: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    /// Where the preview is, in the leaving song's time (for the green line).
    @Published private(set) var position: Double?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var handover = 0.0

    func toggle(plan: TransitionPlan, outgoing: URL, incoming: URL) {
        if isPlaying || isPreparing {
            stop()
            return
        }
        PlayerController.shared.pause()
        isPreparing = true
        task = Task {
            let url = FileManager.default.temporaryDirectory.appending(path: "onda-mix-preview.caf")
            do {
                _ = try await AutoMixRenderer.render(MixSchedule(plan: plan), outgoing: outgoing, incoming: incoming,
                                                     outgoingGain: 1, incomingGain: 1, to: url)
                guard !Task.isCancelled else { return }
                let player = try AVAudioPlayer(contentsOf: url)
                try? AVAudioSession.sharedInstance().setActive(true)
                player.currentTime = max(0, plan.outStart - plan.handover - 4)
                player.play()
                self.player = player
                handover = plan.handover
                isPreparing = false
                isPlaying = true
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch {
                isPreparing = false
            }
        }
    }

    private func tick() {
        guard let player else { return }
        guard player.isPlaying else { return stop() }
        position = handover + player.currentTime
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
        isPreparing = false
        position = nil
    }
}
