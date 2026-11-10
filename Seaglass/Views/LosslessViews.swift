import SwiftUI
import UniformTypeIdentifiers

/// Impostazioni › Audio › Lossless: whether Seaglass looks for lossless copies, the user's own files
/// and their OpenSubsonic server. Nothing here is a service of Seaglass's: the files and the server are
/// the user's.
struct LosslessSettingsSection: View {
    @AppStorage(Preferences.losslessSearch) private var search = true
    @AppStorage(Preferences.losslessCellular) private var cellular = false
    @ObservedObject private var files = LocalLosslessLibrary.shared
    @State private var server: String?

    var body: some View {
        Section {
            Toggle(isOn: $search) {
                Label("Cerca versioni lossless", systemImage: "waveform.badge.magnifyingglass")
            }
            NavigationLink { LocalLosslessView() } label: {
                LabeledContent {
                    Text(verbatim: files.entries.isEmpty ? "" : "\(files.entries.count)")
                } label: {
                    Label("File lossless personali", systemImage: "folder")
                }
            }
            NavigationLink { OpenSubsonicSettingsView() } label: {
                LabeledContent {
                    Text(server ?? String(localized: "Non configurato"))
                } label: {
                    Label("Server OpenSubsonic", systemImage: "server.rack")
                }
            }
            Toggle(isOn: $cellular) {
                Label("Lossless su rete cellulare", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(!search)
        } header: {
            Text(verbatim: "Lossless")
        } footer: {
            Text("Seaglass usa i tuoi file FLAC o ALAC e il tuo server OpenSubsonic (come Navidrome) quando hanno lo stesso brano, e mostra il formato che suona davvero. Se non lo trovano entro pochi secondi, o smettono di funzionare, il brano continua da YouTube.")
        }
        .onAppear { server = UserDefaults.standard.string(forKey: OpenSubsonicSettings.serverKey).flatMap { URL(string: $0)?.host() } }
    }
}

/// The imported lossless files: import, play, delete.
struct LocalLosslessView: View {
    @EnvironmentObject private var player: PlayerController
    @ObservedObject private var files = LocalLosslessLibrary.shared
    @State private var importing = false
    @State private var working = false
    @State private var result: (imported: Int, rejected: [LocalLosslessLibrary.Rejection])?

    var body: some View {
        List {
            if files.entries.isEmpty {
                ContentUnavailableView {
                    Label("Nessun file lossless", systemImage: "waveform")
                } description: {
                    Text("Importa file FLAC, ALAC, WAV o AIFF: restano sul dispositivo come sono e suonano al posto dello stream quando corrispondono al brano.")
                } actions: {
                    Button("Importa") { importing = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Section {
                    ForEach(files.entries) { entry in
                        Button {
                            let tracks = files.entries.map { files.track(for: $0) }
                            let start = files.entries.firstIndex(of: entry) ?? 0
                            player.play(tracks, startAt: start, source: String(localized: "File lossless personali"))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).foregroundStyle(.primary)
                                Text(verbatim: ([entry.artists.joined(separator: ", ")] + [entry.format.label])
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for entry in offsets.map({ files.entries[$0] }) { files.remove(entry) }
                    }
                } footer: {
                    Text("Suonano al posto dello stream quando titolo, artista, durata e versione corrispondono al brano. Restano sul dispositivo finché non li elimini.")
                }
            }
        }
        .overlay { if working { ProgressView() } }
        .navigationTitle("File lossless personali")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { importing = true } label: { Label("Importa", systemImage: "plus") }
                    .disabled(working)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: LocalLosslessLibrary.types, allowsMultipleSelection: true) { picked in
            guard case .success(let urls) = picked, !urls.isEmpty else { return }
            working = true
            Task {
                result = await files.importFiles(urls)
                working = false
            }
        }
        .alert(String(localized: "Importazione"), isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("OK", role: .cancel) { result = nil }
        } message: {
            if let result {
                let rejected = result.rejected.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
                Text("File importati: \(result.imported)") + Text(verbatim: rejected.isEmpty ? "" : "\n\n" + rejected)
            }
        }
    }
}

/// The user's OpenSubsonic server: its address, user and password, checked before they are kept.
struct OpenSubsonicSettingsView: View {
    @State private var address = UserDefaults.standard.string(forKey: OpenSubsonicSettings.serverKey) ?? ""
    @State private var username = UserDefaults.standard.string(forKey: OpenSubsonicSettings.userKey) ?? ""
    @State private var password = ""
    @State private var status: String?
    @State private var checking = false
    @State private var configured = false

    var body: some View {
        Form {
            Section {
                TextField("Indirizzo del server", text: $address, prompt: Text(verbatim: "https://music.example.com"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Nome utente", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(configured ? String(localized: "Password (salvata)") : String(localized: "Password"), text: $password)
                    .textContentType(.password)
            } footer: {
                Text("Il tuo server Navidrome, o un altro compatibile con OpenSubsonic, su HTTPS. La password resta nel portachiavi del dispositivo e ogni richiesta usa un token al suo posto. I file suonano come sono sul server, senza conversioni.")
            }
            Section {
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Prova e salva")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(checking || address.isEmpty || username.isEmpty || (password.isEmpty && !configured))
                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if configured {
                Section {
                    Button("Rimuovi server", role: .destructive) {
                        OpenSubsonicSettings.clear()
                        address = ""
                        username = ""
                        password = ""
                        configured = false
                        status = nil
                    }
                }
            }
        }
        .navigationTitle("Server OpenSubsonic")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { configured = OpenSubsonicSettings.isConfigured }
    }

    /// Pings the server with what was typed (the saved password when none is), and keeps it if it answers.
    private func check() async {
        guard let server = OpenSubsonicSettings.serverURL(from: address) else {
            status = OpenSubsonicError.notHTTPS.localizedDescription
            return
        }
        let secret = password.isEmpty ? (OpenSubsonicSettings.client?.password ?? "") : password
        let client = OpenSubsonicClient(server: server, username: username.trimmingCharacters(in: .whitespaces), password: secret)
        checking = true
        defer { checking = false }
        do {
            let info = try await client.ping()
            OpenSubsonicSettings.save(server: server, username: client.username, password: secret)
            address = server.absoluteString
            password = ""
            configured = true
            let name = [info.type, info.version].compactMap { $0 }.joined(separator: " ")
            status = String(localized: "Collegato: \(name.isEmpty ? (server.host() ?? "") : name)")
        } catch {
            status = error.localizedDescription
        }
    }
}
