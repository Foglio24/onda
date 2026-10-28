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
        if isCustom(design) { return MixPreset.custom.title }
        switch self {
        case .volume: return design.volume.title
        case .eq: return design.eq.title
        case .filter: return design.filter.title
        case .effects: return design.effect.title
        case .loop: return design.loop.title
        }
    }

    /// The lines of this part that can be drawn by hand (none for looping).
    var lines: [MixLine] {
        switch self {
        case .volume: return [.outgoingVolume, .incomingVolume]
        case .eq: return [.outgoingBass, .incomingBass]
        case .filter: return [.outgoingFilter, .incomingFilter]
        case .effects: return [.effect]
        case .loop: return []
        }
    }

    /// The parts with lines to draw.
    static var drawable: [MixCategory] { allCases.filter { !$0.lines.isEmpty } }

    /// Some of its lines are drawn by hand.
    func isCustom(_ design: MixDesign) -> Bool {
        lines.contains { design.lines?[$0] != nil }
    }
}

extension MixLine {
    var category: MixCategory {
        switch self {
        case .outgoingVolume, .incomingVolume: return .volume
        case .outgoingBass, .incomingBass: return .eq
        case .outgoingFilter, .incomingFilter: return .filter
        case .effect: return .effects
        }
    }
}

/// What opens the Mix at launch (`LaunchScene`), or from anywhere through `AppRouter`.
struct MixTarget: Identifiable {
    let id = UUID()
    let playlistID: UUID
    var opensFirst = false
    var options: MixCategory?
    var editing: MixCategory?
}

// MARK: Playlist

/// A playlist's Mix: on or off, and the transition between each pair of songs, each opened in
/// `TransitionEditorView`. It plays on any playlist (songs not downloaded are mixed as AutoMix
/// mixes them, from the copy streamed anyway); a transition is edited from the two songs' files,
/// so only between downloaded songs.
struct PlaylistMixView: View {
    let playlistID: UUID
    var opensFirst = false
    var opensOptions: MixCategory?
    var opensEditing: MixCategory?

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
                                         to: playlist.tracks[index + 1], opensOptions: opensOptions,
                                         opensEditing: opensEditing)
                }
            }
        }
        .onAppear {
            if opensFirst, path.isEmpty { path = [0] }
        }
    }

    private func content(_ playlist: Playlist) -> some View {
        let downloaded = !playlist.tracks.isEmpty && playlist.tracks.allSatisfy { downloads.isDownloaded($0) }
        func editable(_ index: Int) -> Bool {
            downloads.isDownloaded(playlist.tracks[index]) && downloads.isDownloaded(playlist.tracks[index + 1])
        }
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
                    Text("Le transizioni tra i brani della playlist come le scegli tu: preset, volume, EQ, filtri, effetti e loop. Suonano quando ascolti la playlist, anche con AutoMix spento; dove non cambi nulla decide AutoMix.")
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
                        Text("Per modificare una transizione servono i due brani scaricati: vengono analizzati dai loro file, senza usare dati. Gli altri brani sono mixati mentre li ascolti, come fa AutoMix.")
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
                    .disabled(!editable(index))
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

/// One transition of the Mix, as Spotify's editor: both songs' waveforms overlapping in a box that
/// stands for the bars they play together, with the volume, bass, filter and effect lines over
/// them. Drag a song sideways to move where it leaves or comes in (the box keeps its length: that
/// is the bars' choice), or draw the lines by hand (Personalizza); then the presets, the five
/// parts, beatmatching and a preview of the mix.
struct TransitionEditorView: View {
    let playlistID: UUID
    let from: Track
    let to: Track
    var opensOptions: MixCategory?
    var opensEditing: MixCategory?

    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = MixPreview()
    @State private var design = MixDesign()
    @State private var analyses: (outgoing: TrackAnalysis, incoming: TrackAnalysis)?
    @State private var waves: (outgoing: MixWaveform, incoming: MixWaveform)?
    @State private var failed = false
    @State private var options: MixCategory?
    @State private var showsBars = false
    /// A song dragged sideways: the upper one (leaving) or the lower one, and by how many points.
    @State private var slide: (outgoing: Bool, offset: CGFloat)?
    /// The part whose lines are being drawn by hand.
    @State private var editing: MixCategory?
    /// Lines given their option's shape when drawing started (taken away again if left as they
    /// were), and the effect chosen for drawing when there was none.
    @State private var seeded: [MixLine: MixCurve] = [:]
    @State private var seededEffect: MixEffect?
    /// The point held while drawing.
    @State private var grab: Grab?
    @State private var touches = 0

    private struct Grab {
        let line: MixLine
        var index: Int
        /// Added by this touch (so lifting the finger doesn't take it away).
        let added: Bool
        /// From the finger to the point, so it doesn't jump when taken.
        let offset: CGSize
    }

    /// Points of a line stay this far apart (of the overlap).
    private static let gap = 0.012

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
                if editing != nil { editBar }
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
                    Button {
                        editing = nil
                        design = MixDesign(beatmatch: canBeatmatch)
                    } label: {
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
        .sensoryFeedback(.selection, trigger: touches)
        .task { await load() }
        .onDisappear { preview.stop() }
        .sheet(item: $options) { category in
            MixOptionsSheet(design: $design, start: category) { chosen in
                options = nil
                beginEditing(chosen)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsBars) {
            if let analyses {
                MixBarsSheet(choices: MixDesigner.barChoices(from: analyses.outgoing, to: analyses.incoming, design: design),
                             selected: plan.map(MixDesigner.bars(of:)) ?? 0) { bars in setBars(bars) }
            }
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
        VStack(spacing: 0) {
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
                        let scene = MixDrawing.Scene(plan: plan, outgoing: waves.outgoing, incoming: waves.incoming,
                                                     beats: gridBeats(plan), playhead: preview.position, slide: slide,
                                                     editing: editing?.lines ?? [], held: grab.map { ($0.line, $0.index) })
                        Canvas { context, canvasSize in
                            MixDrawing.draw(scene, in: &context, size: canvasSize, box: Self.box(in: canvasSize))
                        }
                        .allowsHitTesting(false)
                    } else if !failed {
                        ProgressView()
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(touch(size: size))
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
            }
            .frame(height: 330)
            if editing == nil {
                pills
                    .padding(.top, -22)
            }
        }
    }

    /// Under the box, as Spotify's: how many bars the mix lasts, and drawing the lines by hand.
    private var pills: some View {
        HStack(spacing: 10) {
            Button { showsBars = true } label: {
                HStack(spacing: 6) {
                    Text("\(plan.map(MixDesigner.bars(of:)) ?? 0) barre")
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            Button { beginEditing(.volume) } label: {
                Label("Personalizza", systemImage: "scribble.variable")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .disabled(plan == nil)
    }

    /// While drawing: which part's lines, back to the option's, done; and how it works.
    private var editBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(MixCategory.drawable) { category in
                            let selected = editing == category
                            Button { switchEditing(to: category) } label: {
                                Text(category.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(selected ? Color.black : Color.primary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(selected ? Glass.regular.tint(category.color).interactive() : Glass.regular.interactive(),
                                         in: .capsule)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                Button { resetLines() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Ripristina")
                Button { endEditing() } label: {
                    Text("Fine")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.green).interactive(), in: .capsule)
            }
            Text(editingHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var editingHint: String {
        let basic = String(localized: "Trascina i punti per cambiare le linee. Tocca una linea per aggiungere un punto, tocca un punto per toglierlo.")
        switch editing {
        case .eq:
            return basic + " " + String(localized: "In alto i bassi ci sono tutti, in basso sono tolti.")
        case .filter:
            return basic + " " + String(localized: "A metà altezza il filtro è aperto: più su è un passa alto, più giù un passa basso.")
        case .effects:
            return basic + " " + String(localized: "Più in alto, più il brano che esce va nell'effetto: \(design.effect.title).")
        default:
            return basic
        }
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
        editing = nil
        seeded = [:]
        var next = MixDesign.preset(preset)
        next.beatmatch = design.beatmatch
        next.overlap = design.overlap
        next.shift = design.shift
        next.incomingShift = design.incomingShift
        design = next
    }

    private func setBars(_ bars: Int) {
        guard let analyses else { return }
        var next = design
        next.overlap = Double(bars) * 4 * analyses.outgoing.beatLength
        design = MixDesigner.normalized(next, from: analyses.outgoing, to: analyses.incoming)
        touches += 1
    }

    /// Outside drawing, a finger slides a song sideways; while drawing, it moves, adds and takes
    /// away the points of the lines.
    private func touch(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: editing == nil ? 6 : 0)
            .onChanged { value in
                if editing != nil {
                    draw(value, size: size)
                } else {
                    slide = (value.startLocation.y < size.height / 2, value.translation.width)
                }
            }
            .onEnded { value in
                if editing != nil {
                    finishDrawing(value)
                } else {
                    settleSlide(value.translation.width, outgoing: value.startLocation.y < size.height / 2, size: size)
                }
            }
    }

    /// A song slid sideways: the upper one changes where it leaves, the lower one where it comes
    /// in, in whole bars with beatmatching (and only as far as the mix can be made). The box, the
    /// length of the mix, stays as it is.
    private func settleSlide(_ translation: CGFloat, outgoing: Bool, size: CGSize) {
        defer { slide = nil }
        guard let plan, let analyses else { return }
        // Dragging to the left brings later music into the box.
        let seconds = -Double(translation) * plan.overlap / Double(max(1, Self.box(in: size).width))
        let matched = plan.style == .beatMatched
        var next = design
        if outgoing {
            let step = matched ? plan.barLength : 0.5
            next.shift = ((design.shift + seconds) / step).rounded() * step
        } else {
            // In the next song's own seconds: it plays at its tempo against this one's.
            let own = seconds * plan.tempoOut / plan.tempoIn
            let step = matched ? 4 * analyses.incoming.beatLength : 0.5
            next.incomingShift = (((design.incomingShift ?? 0) + own) / step).rounded() * step
        }
        let normalized = MixDesigner.normalized(next, from: analyses.outgoing, to: analyses.incoming)
        if normalized != design {
            design = normalized
            touches += 1
        }
    }

    /// Starts drawing a part's lines: each one not drawn yet takes its option's shape (an effect
    /// line starts from a reverb when there is no effect).
    private func beginEditing(_ category: MixCategory) {
        guard let analyses, !category.lines.isEmpty else { return }
        preview.stop()
        var next = design
        seededEffect = nil
        if category == .effects, next.effect == .none {
            seededEffect = next.effect
            next.effect = .reverbOutEnd
        }
        let plan = MixDesigner.plan(from: analyses.outgoing, to: analyses.incoming, design: next)
        seeded = [:]
        for line in category.lines where next.lines?[line] == nil {
            next.setLine(line, MixCurve.tracing { line.value(in: plan.levels(at: $0)) })
            seeded[line] = next.lines?[line]
        }
        design = next
        editing = category
    }

    /// Lines left as their option drew them go back to being the option.
    private func endEditing() {
        if let category = editing {
            var untouched = true
            for line in category.lines {
                if let start = seeded[line], design.lines?[line] == start {
                    design.setLine(line, nil)
                } else if seeded[line] != nil {
                    untouched = false
                }
            }
            if untouched, let seededEffect { design.effect = seededEffect }
        }
        seeded = [:]
        seededEffect = nil
        grab = nil
        editing = nil
    }

    private func switchEditing(to category: MixCategory) {
        guard category != editing else { return }
        endEditing()
        beginEditing(category)
    }

    /// The part's lines back to its option's shape.
    private func resetLines() {
        guard let category = editing else { return }
        let effect = seededEffect
        for line in category.lines { design.setLine(line, nil) }
        editing = nil
        beginEditing(category)
        if let effect { seededEffect = effect }
        touches += 1
    }

    private func draw(_ value: DragGesture.Value, size: CGSize) {
        guard let category = editing, let plan else { return }
        let box = Self.box(in: size)
        let lanes = MixDrawing.lanes(in: size)
        if grab == nil {
            let start = value.startLocation
            let upper = start.y < size.height / 2
            guard let line = category.lines.first(where: { $0.isOutgoing == upper }) else { return }
            let lane = upper ? lanes.top : lanes.bottom
            var curve = design.lines?[line] ?? MixCurve.tracing { line.value(in: plan.levels(at: $0)) }
            let points = curve.points.map { MixDrawing.screen($0, box: box, lane: lane) }
            if let nearest = points.indices.min(by: { Self.distance(points[$0], start) < Self.distance(points[$1], start) }),
               Self.distance(points[nearest], start) < 30 {
                grab = Grab(line: line, index: nearest, added: false,
                            offset: CGSize(width: points[nearest].x - start.x, height: points[nearest].y - start.y))
            } else {
                // A new point where the line was touched.
                let x = Double((start.x - box.minX) / box.width)
                guard let after = curve.points.firstIndex(where: { $0.x > x }), after > 0,
                      x - curve.points[after - 1].x >= Self.gap, curve.points[after].x - x >= Self.gap else { return }
                curve.points.insert(MixPoint(x: x, y: Self.level(at: start.y, in: lane, for: line)), at: after)
                design.setLine(line, curve)
                design.preset = .custom
                grab = Grab(line: line, index: after, added: true, offset: .zero)
            }
            touches += 1
        }
        guard let grab, var curve = design.lines?[grab.line] else { return }
        let lane = grab.line.isOutgoing ? lanes.top : lanes.bottom
        let location = CGPoint(x: value.location.x + grab.offset.width, y: value.location.y + grab.offset.height)
        let index = grab.index, last = curve.points.count - 1
        guard curve.points.indices.contains(index) else { return }
        var point = curve.points[index]
        if index > 0, index < last {
            let x = Double((location.x - box.minX) / box.width)
            point.x = min(max(x, curve.points[index - 1].x + Self.gap), curve.points[index + 1].x - Self.gap)
        }
        let fixed = index == 0 ? grab.line.fixedStart : (index == last ? grab.line.fixedEnd : nil)
        if fixed == nil { point.y = Self.level(at: location.y, in: lane, for: grab.line) }
        guard point != curve.points[index] else { return }
        curve.points[index] = point
        design.setLine(grab.line, curve)
        design.preset = .custom
    }

    /// A tap on a point (not one just added, nor the ends) takes it away.
    private func finishDrawing(_ value: DragGesture.Value) {
        defer { grab = nil }
        guard let grab, !grab.added, hypot(value.translation.width, value.translation.height) < 4,
              var curve = design.lines?[grab.line], grab.index > 0, grab.index < curve.points.count - 1 else { return }
        curve.points.remove(at: grab.index)
        design.setLine(grab.line, curve)
        design.preset = .custom
        touches += 1
    }

    /// A line's value at a height of its lane; a filter snaps open in the middle.
    private static func level(at y: CGFloat, in lane: CGRect, for line: MixLine) -> Double {
        let value = max(0, min(1, Double((lane.maxY - y) / lane.height)))
        if line.category == .filter, abs(value - 0.5) < 0.04 { return 0.5 }
        return value
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// The song leaving's beats around the mix, for the grid in the box.
    private func gridBeats(_ plan: TransitionPlan) -> [(time: Double, downbeat: Bool)] {
        guard let outgoing = analyses?.outgoing, outgoing.isGridLocked else { return [] }
        let margin = plan.overlap * 0.7
        var beats: [(time: Double, downbeat: Bool)] = []
        var beat = outgoing.beat(atOrAfter: plan.outStart - margin)
        while outgoing.beatTime(beat) <= plan.outEnd + margin, beats.count < 600 {
            beats.append((outgoing.beatTime(beat), outgoing.isDownbeat(beat)))
            beat += 1
        }
        return beats
    }

    private func togglePreview() {
        guard let plan, let fileA = Self.file(for: from), let fileB = Self.file(for: to) else { return }
        preview.toggle(plan: plan, outgoing: fileA, incoming: fileB)
    }

    private func save() {
        endEditing()
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
        // The whole songs, so either can be slid to any part of it.
        async let waveA = MixWaveform.make(file: fileA, from: 0, to: analysisA.duration)
        async let waveB = MixWaveform.make(file: fileB, from: 0, to: analysisB.duration)
        if let a = await waveA, let b = await waveB { waves = (a, b) }
        if let opensOptions { options = opensOptions }
        if let opensEditing { beginEditing(opensEditing) }
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

/// How many bars the mix lasts, as Spotify's: 2, 4, 8 or 16 (those the songs allow).
private struct MixBarsSheet: View {
    let choices: [(bars: Int, available: Bool)]
    let selected: Int
    let choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ForEach(choices, id: \.bars) { choice in
                    let isSelected = choice.bars == selected
                    Button { choose(choice.bars) } label: {
                        Text("\(choice.bars) barre")
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(isSelected ? Color.black : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .contentShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(isSelected ? Glass.regular.tint(.white).interactive() : Glass.regular.interactive(),
                                 in: .rect(cornerRadius: 16))
                    .disabled(!choice.available)
                    .opacity(choice.available ? 1 : 0.4)
                }
            }
            Text("Scegli la durata della transizione delle tracce.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(190)])
        .presentationBackground(.regularMaterial)
    }
}

// MARK: Options

/// The options of the five parts, one page each (swipe between them), as in Spotify's Mix.
struct MixOptionsSheet: View {
    @Binding var design: MixDesign
    let start: MixCategory
    /// Draw a part's lines by hand (Personalizza).
    var customize: ((MixCategory) -> Void)?
    @State private var page: MixCategory = .volume

    var body: some View {
        VStack(spacing: 0) {
            pages
            // The page dots, under the list (not over its last option).
            HStack(spacing: 8) {
                ForEach(MixCategory.allCases) { category in
                    Circle()
                        .fill(category == page ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.vertical, 12)
        }
        .presentationBackground(.regularMaterial)
        .onAppear { page = start }
    }

    private var pages: some View {
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
                        if let customize, !category.lines.isEmpty {
                            let custom = category.isCustom(design)
                            Button { customize(category) } label: {
                                Label(custom ? String(localized: "Personalizzato") : String(localized: "Personalizza"),
                                      systemImage: custom ? "checkmark" : "scribble.variable")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
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
                }
                .tag(category)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private struct Row {
        let title: String
        let selected: Bool
        let choose: () -> Void
    }

    private func rows(for category: MixCategory) -> [Row] {
        // Choosing an option takes the place of the part's lines drawn by hand.
        let drawn = category.isCustom(design)
        func custom(_ change: @escaping (inout MixDesign) -> Void) -> () -> Void {
            {
                change(&design)
                for line in category.lines { design.setLine(line, nil) }
                design.preset = .custom
            }
        }
        switch category {
        case .volume:
            return MixVolume.allCases.map { option in
                Row(title: option.title, selected: !drawn && design.volume == option, choose: custom { $0.volume = option })
            }
        case .eq:
            return MixEQ.allCases.map { option in
                Row(title: option.title, selected: !drawn && design.eq == option, choose: custom { $0.eq = option })
            }
        case .filter:
            return MixFilter.allCases.map { option in
                Row(title: option.title, selected: !drawn && design.filter == option, choose: custom { $0.filter = option })
            }
        case .effects:
            return MixEffect.allCases.map { option in
                Row(title: option.title, selected: !drawn && design.effect == option, choose: custom { $0.effect = option })
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

/// Draws the editor: the beat grid in the box, the waveforms (the song leaving on top, warm
/// colours; the next one below, blue; faded where they don't play in the mix) and the lines of the
/// mix over them, all in the leaving song's time.
enum MixDrawing {
    struct Scene {
        var plan: TransitionPlan
        var outgoing: MixWaveform
        var incoming: MixWaveform
        /// The song leaving's beats around the mix, and whether each starts a bar.
        var beats: [(time: Double, downbeat: Bool)]
        var playhead: Double?
        /// A song being slid sideways, by so many points.
        var slide: (outgoing: Bool, offset: CGFloat)?
        /// Lines being drawn by hand (their points shown), and the point held.
        var editing: [MixLine]
        var held: (line: MixLine, index: Int)?
    }

    /// The song leaving's lane (top) and the next one's.
    static func lanes(in size: CGSize) -> (top: CGRect, bottom: CGRect) {
        (CGRect(x: 0, y: size.height * 0.06, width: size.width, height: size.height * 0.4),
         CGRect(x: 0, y: size.height * 0.54, width: size.width, height: size.height * 0.4))
    }

    /// Where a point of a line is drawn.
    static func screen(_ point: MixPoint, box: CGRect, lane: CGRect) -> CGPoint {
        CGPoint(x: box.minX + CGFloat(point.x) * box.width, y: lane.maxY - CGFloat(point.y) * lane.height)
    }

    static func draw(_ scene: Scene, in context: inout GraphicsContext, size: CGSize, box: CGRect) {
        let plan = scene.plan
        let scale = Double(box.width) / max(0.5, plan.overlap)
        let lanes = Self.lanes(in: size)
        let topOffset = scene.slide.map { $0.outgoing ? $0.offset : 0 } ?? 0
        let bottomOffset = scene.slide.map { $0.outgoing ? 0 : $0.offset } ?? 0
        let x = { (time: Double) -> CGFloat in box.minX + CGFloat((time - plan.outStart) * scale) }
        // The next song's time in the leaving song's, while they play together.
        let ratio = plan.tempoIn / plan.tempoOut
        let fromIncoming = { (time: Double) -> Double in plan.outStart + (time - plan.inStart) * ratio }

        // The beat grid, a bar line stronger, inside the box.
        context.drawLayer { layer in
            layer.clip(to: Path(roundedRect: box, cornerRadius: 24, style: .continuous))
            for beat in scene.beats {
                let position = x(beat.time) + topOffset
                guard position > box.minX - 2, position < box.maxX + 2 else { continue }
                var line = Path()
                line.move(to: CGPoint(x: position, y: 0))
                line.addLine(to: CGPoint(x: position, y: size.height))
                layer.stroke(line, with: .color(.white.opacity(beat.downbeat ? 0.13 : 0.05)), lineWidth: beat.downbeat ? 1.2 : 1)
            }
        }

        // The song leaving, bright up to the end of the box (it has gone after it); the next one
        // bright from the start of the box.
        let warm = [Color(red: 0.86, green: 0.58, blue: 0.32), Color(red: 0.55, green: 0.33, blue: 0.16),
                    Color(red: 0.97, green: 0.92, blue: 0.82)]
        let cool = [Color(red: 0.15, green: 0.24, blue: 0.78), Color(red: 0.55, green: 0.33, blue: 0.16),
                    Color(red: 0.97, green: 0.92, blue: 0.82)]
        waveform(scene.outgoing, lane: lanes.top, width: max(1, CGFloat(scene.outgoing.step * scale) * 0.9), colors: warm,
                 in: &context, size: size, position: { x($0) + topOffset }, bright: { $0 <= box.maxX })
        waveform(scene.incoming, lane: lanes.bottom, width: max(1, CGFloat(scene.incoming.step * scale * ratio) * 0.9),
                 colors: cool, in: &context, size: size, position: { x(fromIncoming($0)) + bottomOffset },
                 bright: { $0 >= box.minX })

        // The lines: volumes (blue), bass (yellow), filters (pink) and effect (white). Lines drawn
        // by hand follow their points; while drawing, the other parts' lines fade.
        let design = plan.design ?? MixDesign()
        let editing = Set(scene.editing)
        for line in MixLine.allCases where editing.contains(line) || shows(line, design) {
            let lane = line.isOutgoing ? lanes.top : lanes.bottom
            var path = Path()
            if let curve = design.lines?[line] {
                for (index, point) in curve.points.enumerated() {
                    let position = screen(point, box: box, lane: lane)
                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
            } else {
                for step in 0...160 {
                    let progress = Double(step) / 160
                    let position = screen(MixPoint(x: progress, y: line.value(in: plan.levels(at: progress))), box: box, lane: lane)
                    if step == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
            }
            let faded = !editing.isEmpty && !editing.contains(line)
            context.stroke(path, with: .color(line.category.color.opacity(faded ? 0.3 : 1)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        // The points of the lines being drawn; the fixed ends smaller.
        for line in scene.editing {
            guard let curve = design.lines?[line] else { continue }
            let lane = line.isOutgoing ? lanes.top : lanes.bottom
            let last = curve.points.count - 1
            for (index, point) in curve.points.enumerated() {
                let fixed = (index == 0 && line.fixedStart != nil) || (index == last && line.fixedEnd != nil)
                let held = scene.held.map { $0.line == line && $0.index == index } ?? false
                let radius: CGFloat = held ? 10 : (fixed ? 4 : 7)
                let center = screen(point, box: box, lane: lane)
                let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.fill(dot, with: .color(.white))
                context.stroke(dot, with: .color(line.category.color), lineWidth: 2.5)
            }
        }

        if let playhead = scene.playhead {
            let position = x(playhead)
            var line = Path()
            line.move(to: CGPoint(x: position, y: 0))
            line.addLine(to: CGPoint(x: position, y: size.height))
            context.stroke(line, with: .color(.green), lineWidth: 3)
        }
    }

    /// The lines a design's options draw (volumes always; the others when the part does something).
    private static func shows(_ line: MixLine, _ design: MixDesign) -> Bool {
        if design.lines?[line] != nil { return line != .effect || design.effect != .none }
        switch line.category {
        case .volume: return true
        case .eq: return design.eq != MixEQ.none
        case .filter: return design.filter != .none
        case .effects: return design.effect != .none
        case .loop: return false
        }
    }

    /// One song's waveform: overall loudness, bass and treble, each band in one path per brightness.
    private static func waveform(_ wave: MixWaveform, lane: CGRect, width: CGFloat, colors: [Color],
                                 in context: inout GraphicsContext, size: CGSize, position: (Double) -> CGFloat,
                                 bright: (CGFloat) -> Bool) {
        var paths = [[Path]](repeating: [Path(), Path(), Path()], count: 2)
        let middle = lane.midY, half = lane.height / 2
        for index in wave.full.indices {
            let center = position(wave.start + Double(index) * wave.step)
            guard center > -width, center < size.width + width else { continue }
            let set = bright(center) ? 0 : 1
            let values = [wave.full[index], wave.low[index], wave.high[index]]
            for band in 0..<3 {
                let height = CGFloat(max(0.01, values[band])) * half
                let barWidth = max(1, band == 2 ? width / 2 : width)
                paths[set][band].addRect(CGRect(x: center - barWidth / 2, y: middle - height, width: barWidth, height: height * 2))
            }
        }
        for set in [1, 0] {
            for band in 0..<3 {
                context.fill(paths[set][band], with: .color(colors[band].opacity(set == 0 ? 1 : 0.28)))
            }
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
            let url = FileManager.default.temporaryDirectory.appending(path: "seaglass-mix-preview.caf")
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
