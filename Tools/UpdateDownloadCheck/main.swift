import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [Int64] = []

    func append(_ bytes: Int64) {
        lock.lock()
        writes.append(bytes)
        lock.unlock()
    }

    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }
}

@main struct UpdateDownloadCheck {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() async throws {
        let source = URL(string: CommandLine.arguments[1])!
        let size: Int64 = 1024 * 1024
        let progress = ProgressLog()
        let download = UpdateDownload(expectedBytes: size)
        let (file, response) = try await download.fetch(from: source) { received, total in
            expect(total == size, "uses the release's size as progress total")
            progress.append(received)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        expect((response as? HTTPURLResponse)?.statusCode == 200, "preserves the HTTP response for validation")
        let contents = try Data(contentsOf: file)
        expect(contents == Data(repeating: 120, count: Int(size)), "returns the complete file after the delegate returns")
        expect(!progress.values.isEmpty, "reports bytes during the transfer")
        expect(progress.values == progress.values.sorted(), "download progress never goes backwards")
        expect(progress.values.last == size, "reports all downloaded bytes")

        let cancelledBeforeStart = UpdateDownload(expectedBytes: size)
        cancelledBeforeStart.cancel()
        do {
            _ = try await cancelledBeforeStart.fetch(from: source) { _, _ in }
            expect(false, "cancellation before fetch must fail")
        } catch is CancellationError { }

        let partial = UpdateDownload(expectedBytes: size)
        let partialProgress = ProgressLog()
        do {
            _ = try await partial.fetch(from: source) { received, _ in
                partialProgress.append(received)
                partial.cancel()
            }
            expect(false, "in-flight cancellation must fail")
        } catch is CancellationError { }
        expect(!partialProgress.values.isEmpty, "cancelled a transfer after receiving data")
        expect((partialProgress.values.last ?? size) < size, "cancellation stops before the complete download")

        let oversized = UpdateDownload(expectedBytes: 1)
        do {
            _ = try await oversized.fetch(from: source) { _, _ in }
            expect(false, "a file larger than its release metadata must fail")
        } catch {
            expect((error as? URLError)?.code == .dataLengthExceedsMaximum, "rejects an oversized download")
        }
        print("UpdateDownloadCheck: progress, completion, early cancellation, in-flight cancellation and size limit passed")
    }
}
