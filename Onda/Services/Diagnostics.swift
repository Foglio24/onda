import Combine
import Foundation
import MetricKit

/// Crash and hang reports that iOS collects about Onda (MetricKit), saved so they can be shared
/// from Settings → Diagnostica. iOS hands them over at a later launch, not at the moment it happens.
@MainActor
final class Diagnostics: NSObject, ObservableObject {
    static let shared = Diagnostics()

    struct Report: Identifiable, Hashable {
        let file: URL
        let date: Date
        let summary: String
        var id: URL { file }
    }

    @Published private(set) var reports: [Report] = []

    nonisolated private static let keep = 15

    private nonisolated static var folder: URL {
        let url = Storage.support.appending(path: "Diagnostics", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private override init() {
        super.init()
        reload()
    }

    func start() {
        MXMetricManager.shared.add(self)
        // Reports iOS delivered while the app wasn't listening yet.
        save(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func removeAll() {
        for report in reports { try? FileManager.default.removeItem(at: report.file) }
        reload()
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        reports = files.filter { $0.pathExtension == "json" }.compactMap(Self.report(from:))
            .sorted { $0.date > $1.date }
    }

    nonisolated private func save(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let summary = Self.summary(of: payload)
            let stamp = Int(payload.timeStampEnd.timeIntervalSince1970)
            // The summary goes in the name, so the list needs no parsing.
            let name = "\(stamp)_\(summary.replacingOccurrences(of: "/", with: "-")).json"
            let file = Self.folder.appending(path: name)
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            try? payload.jsonRepresentation().write(to: file, options: .atomic)
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(Self.keep) { try? FileManager.default.removeItem(at: old) }
        Task { @MainActor in Diagnostics.shared.reload() }
    }

    /// "Crash (exception 1, signal 11)", "Hang 3 s", … (technical, so not translated).
    nonisolated private static func summary(of payload: MXDiagnosticPayload) -> String {
        var parts: [String] = []
        for crash in payload.crashDiagnostics ?? [] {
            let details = [crash.exceptionType.map { "exception \($0)" }, crash.signal.map { "signal \($0)" }]
                .compactMap { $0 }.joined(separator: ", ")
            parts.append(details.isEmpty ? "Crash" : "Crash (\(details))")
        }
        for hang in payload.hangDiagnostics ?? [] {
            let seconds = hang.hangDuration.converted(to: .seconds).value
            parts.append("Hang \(Int(seconds.rounded())) s")
        }
        if !(payload.cpuExceptionDiagnostics ?? []).isEmpty { parts.append("CPU") }
        if !(payload.diskWriteExceptionDiagnostics ?? []).isEmpty { parts.append("Disk writes") }
        return parts.isEmpty ? "Report" : parts.joined(separator: " + ")
    }

    nonisolated private static func report(from file: URL) -> Report? {
        let name = file.deletingPathExtension().lastPathComponent
        let pieces = name.split(separator: "_", maxSplits: 1).map(String.init)
        guard pieces.count == 2, let stamp = TimeInterval(pieces[0]) else { return nil }
        return Report(file: file, date: Date(timeIntervalSince1970: stamp), summary: pieces[1])
    }
}

extension Diagnostics: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads)
    }
}
