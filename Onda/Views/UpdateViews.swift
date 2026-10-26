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
    }

    private func header(_ release: AppUpdater.Release) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(accent.color.gradient, in: .rect(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("Onda \(release.version)")
                    .font(.title2.bold())
                Text("Hai la versione \(AppUpdater.currentVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actions(_ release: AppUpdater.Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let file = updater.downloadedFile {
                Label("Scaricata in File › Sul mio iPhone › Onda › \(Storage.updatesFolderName)",
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                ShareLink(item: file) {
                    Label("Condividi l'IPA", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
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
                .buttonStyle(.glassProminent)
            }
            if let error = updater.downloadError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Link(destination: release.page) {
                Label("Apri su GitHub", systemImage: "safari")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
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
