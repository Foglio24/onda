import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The monthly recap as a story (9:16): what `MonthlyRecap` found, drawn for an image the size of a
/// phone's story (1080 × 1920 pixels at 3×). Nothing in it reads the environment, so the image is
/// the same wherever it is made.
struct RecapStoryCard: View {
    let recap: MonthlyRecap
    let tint: Color

    static let size = CGSize(width: 360, height: 640)

    private var monthName: String {
        recap.month.formatted(.dateTime.month(.wide).year()).capitalized(with: .current)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.mix(with: .black, by: 0.1), tint.mix(with: .black, by: 0.62), Color.black],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(.white.opacity(0.09)).frame(width: 340).offset(x: 150, y: -260)
            Circle().fill(.white.opacity(0.05)).frame(width: 280).offset(x: -160, y: 250)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 15, weight: .bold))
                    Text(verbatim: "Seaglass")
                        .font(.system(size: 15, weight: .bold))
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Il tuo mese")
                        .font(.system(size: 13, weight: .bold))
                        .textCase(.uppercase)
                        .opacity(0.75)
                    Text(monthName)
                        .font(.system(size: 34, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                if recap.listens == 0 {
                    empty
                } else if recap.hasFewListens {
                    few
                } else {
                    full
                }
                Spacer(minLength: 0)
                if let from = recap.coveredFrom {
                    Text("Ascolti registrati su questo dispositivo dal \(from.formatted(date: .long, time: .omitted)).")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .foregroundStyle(.white)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text(recap.minutes.formatted())
                    .font(.system(size: 64, weight: .black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("minuti di ascolto")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(recap.listens) ascolti · \(recap.artistCount) artisti")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.75)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Artisti più ascoltati")
                    .font(.system(size: 13, weight: .bold))
                    .textCase(.uppercase)
                    .opacity(0.75)
                ForEach(Array(recap.topArtists.enumerated()), id: \.offset) { place, artist in
                    HStack(spacing: 10) {
                        Text(verbatim: "\(place + 1)")
                            .font(.system(size: 15, weight: .heavy))
                            .frame(width: 18, alignment: .leading)
                            .opacity(0.7)
                        Text(artist.name)
                            .font(.system(size: 17, weight: .bold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(artist.listens) ascolti")
                            .font(.system(size: 12, weight: .medium))
                            .opacity(0.75)
                            .lineLimit(1)
                    }
                }
            }
            if let song = recap.topSongs.first {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Brano del mese")
                        .font(.system(size: 13, weight: .bold))
                        .textCase(.uppercase)
                        .opacity(0.75)
                    Text(song.title)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.system(size: 13, weight: .medium))
                        .opacity(0.75)
                        .lineLimit(1)
                }
            }
            discoveries
        }
    }

    @ViewBuilder private var discoveries: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Nuove scoperte")
                .font(.system(size: 13, weight: .bold))
                .textCase(.uppercase)
                .opacity(0.75)
            if let found = recap.discoveries {
                if found.isEmpty {
                    Text("Nessun artista nuovo questo mese")
                        .font(.system(size: 15, weight: .semibold))
                } else {
                    Text("\(found.count) artisti ascoltati per la prima volta")
                        .font(.system(size: 15, weight: .semibold))
                    Text(found.prefix(3).joined(separator: " · "))
                        .font(.system(size: 13, weight: .medium))
                        .opacity(0.8)
                        .lineLimit(1)
                }
            } else {
                Text("Si contano dal mese dopo l'inizio dei dati.")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.8)
            }
        }
    }

    private var few: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pochi ascolti, per ora")
                .font(.system(size: 30, weight: .heavy))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(recap.listens) ascolti e \(recap.minutes) minuti questo mese: la classifica compare da \(MonthlyRecap.fewListens) ascolti.")
                .font(.system(size: 15, weight: .medium))
                .opacity(0.85)
                .fixedSize(horizontal: false, vertical: true)
            if let artist = recap.topArtists.first {
                Text("Finora più di tutti: \(artist.name)")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ancora nessun ascolto questo mese")
                .font(.system(size: 30, weight: .heavy))
                .fixedSize(horizontal: false, vertical: true)
            Text("Il riepilogo si riempie con la musica che ascolti in Seaglass.")
                .font(.system(size: 15, weight: .medium))
                .opacity(0.85)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The card as an image and as a file to share.
@MainActor
enum RecapImage {
    static func render(_ recap: MonthlyRecap, tint: Color) -> UIImage? {
        let renderer = ImageRenderer(content: RecapStoryCard(recap: recap, tint: tint))
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// The PNG in the temporary folder, named after the month (what the share sheet shows and saves).
    static func file(for data: Data, month: Date) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Recap", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "Seaglass \(month.formatted(.iso8601.year().month())).png"
        let url = folder.appending(path: name)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Saves an image in the Photos library, saying when it is done (the system asks for permission the
/// first time: see NSPhotoLibraryAddUsageDescription).
final class PhotoSaver: NSObject {
    private var done: ((Error?) -> Void)?

    func save(_ image: UIImage, done: @escaping (Error?) -> Void) {
        self.done = done
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(saved(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func saved(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        done?(error)
        done = nil
    }
}

/// The image as a document, for a Mac's save panel.
struct PNGFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The monthly recap: the card for the month chosen, shared through the system's menu or saved, as
/// the listener chooses.
struct MonthlyRecapView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.interfaceStyle) private var style
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @State private var month: Date
    @State private var image: UIImage?
    @State private var file: URL?
    @State private var png: Data?
    @State private var message: String?
    @State private var exporting = false
    @State private var saver = PhotoSaver()
    private let events: [ListenEvent]
    private let months: [Date]
    private static let isMac = ProcessInfo.processInfo.isMacCatalystApp

    init() {
        let events = LaunchScene.recapPreviewEvents ?? ListeningLog.shared.events
        self.events = events
        months = MonthlyRecap.months(events: events)
        _month = State(initialValue: months.first ?? .now)
    }

    private var tint: Color { style == .classic ? ClassicPalette.accent : accent.color }

    private var recap: MonthlyRecap {
        let titles = Self.titles()
        return MonthlyRecap.make(events: events, month: month) { titles[$0] }
    }

    /// Titles the library knows, for plays recorded without one (before 1.37.0).
    private static func titles() -> [String: String] {
        let library = Library.shared
        var titles: [String: String] = [:]
        for track in library.history + library.liked + library.downloads + library.playlists.flatMap(\.tracks) {
            if let id = track.videoId, titles[id] == nil { titles[id] = track.title }
        }
        return titles
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if months.count > 1 {
                        Picker("Mese", selection: $month) {
                            ForEach(months, id: \.self) { start in
                                Text(start.formatted(.dateTime.month(.wide).year())).tag(start)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Group {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .accessibilityLabel(Text("Riepilogo del mese"))
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .aspectRatio(9 / 16, contentMode: .fit)
                        }
                    }
                    .frame(maxWidth: 340)
                    .clipShape(.rect(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)

                    HStack(spacing: 12) {
                        if let file, let image {
                            ShareLink(item: file, preview: SharePreview(Text("Riepilogo del mese"), image: Image(uiImage: image))) {
                                Label("Condividi", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .styledButton(prominent: true)
                        }
                        Button(action: save) {
                            Label(Self.isMac ? "Salva immagine…" : "Salva nelle Foto", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .styledButton()
                        .disabled(image == nil)
                    }
                    .controlSize(.large)
                    .frame(maxWidth: 340)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Solo dati registrati su questo dispositivo: un ascolto conta da 30 secondi in su (metà di un brano più breve di un minuto), un brano ripreso dove era rimasto conta una volta, pause e salti nel brano non aggiungono ascolti. Le demo non contano.")
                        Text("L'immagine resta sul dispositivo finché non scegli tu di condividerla o salvarla.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 340, alignment: .leading)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background {
                if style == .classic { ClassicPalette.background.ignoresSafeArea() } else { BrowseBackground() }
            }
            .navigationTitle("Riepilogo del mese")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .fileExporter(isPresented: $exporting, document: png.map(PNGFile.init(data:)), contentType: .png,
                          defaultFilename: "Seaglass \(month.formatted(.iso8601.year().month()))") { result in
                if case .failure(let error) = result { message = error.localizedDescription }
            }
        }
        .tint(tint)
        .task(id: month) { render() }
    }

    private func render() {
        let recap = self.recap
        image = RecapImage.render(recap, tint: tint)
        png = image?.pngData()
        file = png.flatMap { try? RecapImage.file(for: $0, month: recap.month) }
        if LaunchScene.isActive, let image {
            print("recap: card \(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale)), "
                  + "\(recap.listens) listens, \(recap.minutes) min, file \(file?.lastPathComponent ?? "none")")
        }
    }

    private func save() {
        guard let image else { return }
        if Self.isMac {
            exporting = true
            return
        }
        saver.save(image) { error in
            Task { @MainActor in
                message = error?.localizedDescription ?? String(localized: "Immagine salvata nelle Foto.")
            }
        }
    }
}
