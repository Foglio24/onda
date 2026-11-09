import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One update transfer. URLSession's download delegate reports bytes without loading the zip into
/// memory; cancellation also works before the task has started or while its completion is queued.
final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let expectedBytes: Int64
    private var cancelled = false
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var file: URL?
    private var failure: Error?
    private var progress: (@Sendable (Int64, Int64) -> Void)?

    init(expectedBytes: Int64) {
        self.expectedBytes = expectedBytes
    }

    func fetch(from source: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                self.progress = progress
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 60 * 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.downloadTask(with: source)
                self.task = task
                let shouldCancel = cancelled
                lock.unlock()
                task.resume()
                if shouldCancel { task.cancel() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let callback = progress
        let isCancelled = cancelled
        if totalBytesWritten > expectedBytes { failure = URLError(.dataLengthExceedsMaximum) }
        let exceedsSize = failure != nil
        lock.unlock()
        if exceedsSize { downloadTask.cancel() }
        if !isCancelled, !exceedsSize { callback?(totalBytesWritten, expectedBytes) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession removes its temporary file when this callback returns.
        let saved = FileManager.default.temporaryDirectory.appending(path: "Seaglass-update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: saved)
            lock.lock()
            file = saved
            lock.unlock()
        } catch {
            lock.lock()
            failure = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        let file = file
        let failure: Error? = cancelled ? CancellationError() : (failure ?? error)
        self.continuation = nil
        self.session = nil
        self.task = nil
        self.file = nil
        progress = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let failure {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation?.resume(throwing: failure)
        } else if let file, let response = task.response {
            continuation?.resume(returning: (file, response))
        } else {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }
}
