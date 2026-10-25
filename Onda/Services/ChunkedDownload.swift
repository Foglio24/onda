import Foundation

/// Downloads a file in 1 MB ranges, four at a time.
/// YouTube throttles a plain full-file request to about playback speed, but serves ranges at full speed.
enum ChunkedDownload {
    private static let chunkSize = 1 << 20
    private static let parallelRequests = 4

    static func fetch(_ url: URL, to destination: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let first = try await range(url, from: 0, to: chunkSize - 1)
        guard let total = first.total, total > first.data.count else {
            // The server sent the whole file at once (or it fits in one chunk).
            try first.data.write(to: temporary)
            try replace(destination, with: temporary)
            progress?(1)
            return
        }

        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: first.data)
        var received = first.data.count
        progress?(Double(received) / Double(total))

        let offsets = Array(stride(from: first.data.count, to: total, by: chunkSize))
        do {
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var pending = offsets.makeIterator()
                for _ in 0..<parallelRequests {
                    guard let offset = pending.next() else { break }
                    group.addTask { try await chunk(url, at: offset, total: total) }
                }
                while let result = try await group.next() {
                    let (offset, data) = result
                    try handle.seek(toOffset: UInt64(offset))
                    try handle.write(contentsOf: data)
                    received += data.count
                    progress?(Double(received) / Double(total))
                    if let next = pending.next() {
                        group.addTask { try await chunk(url, at: next, total: total) }
                    }
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard received >= total else { throw URLError(.networkConnectionLost) }
        try replace(destination, with: temporary)
    }

    private static func chunk(_ url: URL, at offset: Int, total: Int) async throws -> (Int, Data) {
        let response = try await range(url, from: offset, to: min(offset + chunkSize, total) - 1)
        return (offset, response.data)
    }

    private static func range(_ url: URL, from start: Int, to end: Int) async throws -> (data: Data, total: Int?) {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 200 { return (data, nil) }
        guard http.statusCode == 206 else { throw URLError(.badServerResponse) }
        // "Content-Range: bytes 0-1048575/4123456"
        let total = http.value(forHTTPHeaderField: "Content-Range")?
            .split(separator: "/").last.flatMap { Int($0) }
        return (data, total)
    }

    private static func replace(_ destination: URL, with file: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }
}
