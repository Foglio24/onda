import SwiftUI

/// A newer version from GitHub: its changelog and how to get it.
struct UpdateSheet: View {
    @EnvironmentObject private var updater: AppUpdater
    @AppStorage(Preferences.accent) private var accent: AccentChoice = .pink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let release = updater.latest {
                    VStack(alignment: .leading, spacing: 22) {
                        header(release)
                        actions(release)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Novità")
                                .font(.title3.bold())
                            ReleaseNotesView(markdown: release.notes)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Aggiornamento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Più tardi") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .macUpdateRestartAlert(isActive: true)
    }

    private func header(_ release: AppUpdater.Release) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(accent.color.gradient, in: .rect(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("Seaglass \(release.version)")
                    .font(.title2.bold())
                Text("Hai la versione \(AppUpdater.currentVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actions(_ release: AppUpdater.Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if ProcessInfo.processInfo.isMacCatalystApp {
                MacInstallStatus()
                if !updater.macInstall.isBusyOrReady {
                    Button {
                        Task { await updater.download() }
                    } label: {
                        Label("Scarica", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .styledButton(prominent: true)
                }
            } else if let file = updater.downloadedFile {
                Label("Scaricata in File › Sul mio iPhone › Seaglass › \(Storage.updatesFolderName)",
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                ShareLink(item: file) {
                    Label("Condividi l'IPA", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .styledButton(prominent: true)
            } else if updater.isDownloading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Download in corso…")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                Button {
                    Task { await updater.download() }
                } label: {
                    Label("Scarica", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .styledButton(prominent: true)
            }
            if !ProcessInfo.processInfo.isMacCatalystApp, let error = updater.downloadError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Link(destination: release.page) {
                Label("Apri su GitHub", systemImage: "safari")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .styledButton()
        }
    }
}

/// GitHub release notes: headings, nested bullets and paragraphs, with inline Markdown (bold, links).
struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ReleaseNoteBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(Self.inline(text))
                        .font(.headline)
                        .padding(.top, 6)
                case .bullet(let text, let level):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: level == 0 ? "•" : "◦")
                        Text(Self.inline(text))
                    }
                    .padding(.leading, CGFloat(level) * 18)
                case .paragraph(let text):
                    Text(Self.inline(text))
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Shared by Settings, the update sheet and the window's download banner.
struct MacInstallStatus: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        switch updater.macInstall {
        case .downloading:
            MacUpdateDownloadProgress()
        case .verifying:
            HStack(spacing: 10) {
                ProgressView()
                Text("Verifica dell'aggiornamento…")
            }
        case .ready:
            Button {
                Task { await updater.download() }
            } label: {
                Label("Installa e riavvia", systemImage: "arrow.triangle.2.circlepath")
            }
            Text("Pronta: si installa quando chiudi Seaglass.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.orange)
        case .cancelled:
            Text("Download annullato.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }
}

private extension AppUpdater.MacInstall {
    var isBusyOrReady: Bool {
        switch self {
        case .downloading, .verifying, .ready: true
        default: false
        }
    }
}

/// The same cancellable transfer stays visible after the update sheet is dismissed.
private struct MacUpdateDownloadProgress: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Download in corso…")
                Spacer()
                if let fraction = updater.macDownloadProgress {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                Button("Annulla download", role: .cancel) { updater.cancelMacDownload() }
                    .buttonStyle(.bordered)
            }
            if let fraction = updater.macDownloadProgress {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            if updater.macDownloadedBytes > 0 {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: updater.macDownloadedBytes, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MacUpdateRestartAlert: ViewModifier {
    @EnvironmentObject private var updater: AppUpdater
    let isActive: Bool

    func body(content: Content) -> some View {
        content.alert("Aggiornamento pronto", isPresented: Binding(
            get: { ProcessInfo.processInfo.isMacCatalystApp && isActive && updater.showsRestartPrompt },
            set: { if !$0 && isActive { updater.showsRestartPrompt = false } }
        )) {
            Button("Installa e riavvia") { updater.restartToInstallMac() }
            Button("Più tardi", role: .cancel) { updater.showsRestartPrompt = false }
        } message: {
            Text("Vuoi riavviare Seaglass per installare l'aggiornamento? La riproduzione verrà interrotta.")
        }
    }
}

private struct AppUpdatePresentation: ViewModifier {
    @EnvironmentObject private var updater: AppUpdater
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { isActive && updater.showsNotice },
                set: { if isActive { updater.showsNotice = $0 } }
            )) {
                UpdateSheet().appEnvironment()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if ProcessInfo.processInfo.isMacCatalystApp, isActive, !updater.showsNotice,
                   updater.macInstall == .downloading || updater.macInstall == .verifying {
                    VStack(alignment: .leading, spacing: 8) { MacInstallStatus() }
                        .padding(14)
                        .background(.regularMaterial)
                }
            }
            .macUpdateRestartAlert(isActive: isActive && !updater.showsNotice)
    }
}

extension View {
    func appUpdatePresentation(isActive: Bool) -> some View {
        modifier(AppUpdatePresentation(isActive: isActive))
    }

    fileprivate func macUpdateRestartAlert(isActive: Bool) -> some View {
        modifier(MacUpdateRestartAlert(isActive: isActive))
    }
}
