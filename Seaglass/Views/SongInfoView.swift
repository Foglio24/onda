import SwiftUI

/// "Informazioni sul brano": a song's general data, from the ··· menu of any song or by swiping up
/// in the player. The album and release date, label, copyright and credits come from what the
/// label sent to YouTube Music (see `SongDetails`); the audio part is about this iPhone.
struct SongInfoView: View {
    let track: Track

    @EnvironmentObject private var player: PlayerController
    @State private var details: SongDetails?
    @State private var isLoading = true
    @State private var downloadSize: Int64?

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Section("Brano") {
                if !track.primaryArtist.isEmpty {
                    NavigationLink {
                        ArtistView(id: track.artistID, name: track.primaryArtist)
                    } label: {
                        LabeledContent("Artista", value: track.artist)
                    }
                }
                if let album = track.album ?? details?.album {
                    if let albumID = track.albumID {
                        NavigationLink { AlbumView(id: albumID) } label: { albumRow(album) }
                    } else {
                        albumRow(album)
                    }
                }
                if let date = details?.releaseDate {
                    // A calendar day, written in UTC so no time zone moves it to the day before.
                    LabeledContent("Uscita", value: date.formatted(Date.FormatStyle(date: .long, time: .omitted,
                                                                                    timeZone: .gmt)))
                } else if let date = details?.published {
                    LabeledContent("Su YouTube dal", value: date.formatted(date: .long, time: .omitted))
                }
                if let length = track.duration ?? details?.length {
                    LabeledContent("Durata", value: length.formattedTime)
                }
                if let views = details?.views {
                    LabeledContent("Riproduzioni su YouTube", value: views.formatted())
                }
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }

            if let details, details.label != nil || details.copyright != nil {
                Section("Etichetta") {
                    if let label = details.label {
                        LabeledContent("Distribuito da", value: label)
                    }
                    if let copyright = details.copyright {
                        Text(copyright)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let credits = details?.credits, !credits.isEmpty {
                Section("Crediti") {
                    ForEach(credits, id: \.self) { credit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(credit.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(credit.names.joined(separator: ", "))
                        }
                    }
                }
            }

            audioSection

            if let text = details?.description {
                Section("Descrizione") {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(14)
                }
            }

            if let url = track.shareURL {
                Section {
                    Link(destination: url) {
                        Label("Apri in YouTube Music", systemImage: "arrow.up.forward.app")
                    }
                    ShareLink(item: url) {
                        Label("Condividi", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Informazioni sul brano")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            downloadSize = Self.downloadSize(of: track)
            guard let videoId = track.videoId else {
                isLoading = false
                return
            }
            details = try? await SongDetails.load(videoId: videoId)
            isLoading = false
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ArtworkView(track: track, size: 72, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.title3.bold())
                    .lineLimit(2)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func albumRow(_ album: String) -> some View {
        LabeledContent {
            Text(album)
        } label: {
            // The same word in both languages; the "Album" key is the plural of search's section.
            Text(verbatim: "Album")
        }
    }

    @ViewBuilder private var audioSection: some View {
        let isCurrent = player.current?.id == track.id
        let format = DownloadManager.formatLabel(for: track)
        if (isCurrent && player.streamInfo != nil) || downloadSize != nil || details?.loudness != nil {
            Section {
                if isCurrent, let info = player.streamInfo {
                    LabeledContent("In riproduzione", value: info)
                }
                if let downloadSize {
                    LabeledContent("Scaricato",
                                   value: [format, ByteCountFormatter.string(fromByteCount: downloadSize, countStyle: .file)]
                                    .compactMap { $0 }.joined(separator: " · "))
                }
                if let loudness = details?.loudness {
                    LabeledContent("Volume originale",
                                   value: loudness.formatted(.number.precision(.fractionLength(1))
                                    .sign(strategy: .always())) + " dB")
                }
            } header: {
                Text("Audio")
            } footer: {
                if let loudness = details?.loudness {
                    Text(Self.loudnessNote(loudness))
                }
            }
        }
    }

    /// What "Volume uniforme" does with this song.
    private static func loudnessNote(_ decibels: Double) -> String {
        guard Preferences.normalizesVolume else {
            return String(localized: "Rispetto al livello di riferimento di YouTube (-14 LUFS).")
        }
        guard decibels > 0.1 else {
            return String(localized: "Rispetto al livello di riferimento di YouTube (-14 LUFS): Volume uniforme lo lascia com'è.")
        }
        let lowered = min(decibels, 20).formatted(.number.precision(.fractionLength(1)))
        return String(localized: "Rispetto al livello di riferimento di YouTube (-14 LUFS): Volume uniforme lo abbassa di \(lowered) dB.")
    }

    private static func downloadSize(of track: Track) -> Int64? {
        guard let file = Storage.localAudio(for: track) else { return nil }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0 ? Int64(size) : nil
    }
}
