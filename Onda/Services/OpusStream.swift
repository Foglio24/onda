import AVFoundation
import Foundation

/// Plays a WebM/Opus stream from its first seconds while the rest downloads. The file comes in
/// ranges (the first one read as it arrives), `WebMStreamParser` takes the Opus packets out of it,
/// Apple's Opus decoder turns them into 16-bit PCM, and the PCM goes into a WAV file that grows,
/// which AVPlayer reads through a resource loader (`makeItem()`), waiting where it isn't decoded
/// yet. So the song is an ordinary AVPlayer item (seeks, audio mix, AutoMix, the system's
/// controls), and nothing is converted ahead: the first seconds play once a few kilobytes are in.
///
/// When the whole song is in, the WAV is complete and moves to `destination`, the song's cached
/// file (`completedFile()`). A prepared stream (`start(prepareOnly: true)`) reads only its first
/// range, then waits for `resume()`.
final class OpusStream: NSObject, @unchecked Sendable {
    static let scheme = "onda-opus"
    static let sampleRate = 48_000
    private static let headerSize = 44
    /// Ranges after the first, fetched four at a time: YouTube serves ranges at full speed, a
    /// whole-file request only at about playback speed (see `ChunkedDownload`).
    private static let rangeSize = 1 << 20
    private static let parallelRequests = 4

    enum Source: Sendable {
        /// A web address, read in ranges.
        case remote(URL)
        /// A file's bytes in memory, handed over `chunk` at a time (for the checks).
        case local(Data, chunk: Int)
    }

    enum StreamError: LocalizedError {
        case badResponse
        case decoderUnavailable

        var errorDescription: String? {
            switch self {
            case .badResponse: return String(localized: "Risposta non valida dal server audio.")
            case .decoderUnavailable: return String(localized: "Decoder Opus non disponibile.")
            }
        }
    }

    /// When each step happened (system uptime), for Settings → Diagnostica.
    struct Timing: Sendable {
        var started: TimeInterval?
        var firstByte: TimeInterval?
        /// The head (channels, pre-skip, length) is in.
        var head: TimeInterval?
        /// The first PCM is decoded.
        var firstAudio: TimeInterval?
        var completed: TimeInterval?
    }

    private struct State {
        var timing = Timing()
        var channels = 2
        /// Frames the WAV says it holds (from the file's length), known with the first packets.
        var declaredFrames: Int?
        /// PCM bytes in the file after its header.
        var decodedBytes = 0
        var finished = false
        var failure: Error?
        var completed: URL?
        var completionWaiters: [CheckedContinuation<URL, Error>] = []
        var audioWaiters: [(bytes: Int, continuation: CheckedContinuation<Void, Error>)] = []
        var prepareOnly = false
        var resumeWaiter: CheckedContinuation<Void, Error>?
    }

    /// The address AVPlayer reads the song from (served by the resource loader).
    let playbackURL: URL
    private let source: Source
    private let destination: URL?
    private let fallbackDuration: Double?
    private let firstRange: Int
    private let file: URL
    private let lock = NSLock()
    private var state = State()
    /// Parsing, decoding and writing, in order.
    private let work = DispatchQueue(label: "onda.opus-stream", qos: .userInitiated)
    private var parser = WebMStreamParser()
    private var decoder: OpusPacketDecoder?
    private var writer: FileHandle?
    private var network: Task<Void, Never>?
    /// The resource loader's requests and file reader, on `loaderQueue` only.
    private let loaderQueue = DispatchQueue(label: "onda.opus-stream.loader", qos: .userInitiated)
    private var requests: [AVAssetResourceLoadingRequest] = []
    private var reader: FileHandle?

    /// `duration` (seconds) stands in for the file's own length when it doesn't give one;
    /// `firstRange` is the first range's size in bytes.
    init(source: Source, destination: URL?, duration: Double?, firstRange: Int = 512 << 10) {
        self.source = source
        self.destination = destination
        fallbackDuration = duration
        self.firstRange = firstRange
        let id = UUID().uuidString
        playbackURL = URL(string: "\(Self.scheme)://stream/\(id).wav")!
        let folder = destination?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        file = folder.appending(path: ".\(id).streaming.wav")
        super.init()
    }

    deinit {
        network?.cancel()
        try? writer?.close()
        try? reader?.close()
        if completedURL == nil { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: Control

    /// Starts reading the file; `prepareOnly` stops after the first range until `resume()`.
    func start(prepareOnly: Bool = false) {
        withState { state in
            state.prepareOnly = prepareOnly
            state.timing.started = ProcessInfo.processInfo.systemUptime
        }
        network = Task(priority: .userInitiated) { [weak self] in
            await self?.read()
        }
    }

    /// A prepared stream carries on downloading the rest.
    func resume() {
        let waiter = withState { state -> CheckedContinuation<Void, Error>? in
            state.prepareOnly = false
            defer { state.resumeWaiter = nil }
            return state.resumeWaiter
        }
        waiter?.resume()
    }

    func cancel() {
        network?.cancel()
        work.async { self.fail(CancellationError()) }
    }

    var timing: Timing { withState { $0.timing } }
    var failure: Error? { withState { $0.failure } }
    var completedURL: URL? { withState { $0.completed } }
    /// Seconds of audio decoded so far.
    var decodedSeconds: Double {
        withState { Double($0.decodedBytes) / Double(2 * $0.channels * Self.sampleRate) }
    }

    /// Waits until `seconds` of audio are decoded (or the whole song, if shorter).
    func waitForAudio(seconds: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done = withState { state -> Result<Void, Error>? in
                if let failure = state.failure { return .failure(failure) }
                let bytes = Int(seconds * Double(2 * state.channels * Self.sampleRate))
                if state.finished || (state.declaredFrames != nil && state.decodedBytes >= bytes) { return .success(()) }
                state.audioWaiters.append((bytes, continuation))
                return nil
            }
            if let done { continuation.resume(with: done) }
        }
    }

    /// The finished WAV file, once the whole song is in.
    func completedFile() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let done = withState { state -> Result<URL, Error>? in
                if let completed = state.completed { return .success(completed) }
                if let failure = state.failure { return .failure(failure) }
                state.completionWaiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(with: done) }
        }
    }

    /// An AVPlayer item reading the song through the resource loader. The stream must be kept
    /// alive as long as the item plays (the loader holds it weakly).
    func makeItem() -> AVPlayerItem {
        let asset = AVURLAsset(url: playbackURL)
        asset.resourceLoader.setDelegate(self, queue: loaderQueue)
        return AVPlayerItem(asset: asset)
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    // MARK: Reading

    private func read() async {
        do {
            switch source {
            case .remote(let url):
                let total = try await streamFirstRange(of: url)
                try await waitIfPrepared()
                if total > firstRange { try await fetchRest(of: url, from: firstRange, total: total) }
            case .local(let data, let chunk):
                var offset = 0
                while offset < data.count {
                    try Task.checkCancellation()
                    let end = min(data.count, offset + max(1, chunk))
                    let piece = data.subdata(in: offset..<end)
                    work.async { self.feed(piece) }
                    offset = end
                    if offset >= firstRange { try await waitIfPrepared() }
                }
            }
            work.async { self.finish() }
        } catch {
            work.async { self.fail(error) }
        }
    }

    private func waitIfPrepared() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let waits = withState { state -> Bool in
                guard state.prepareOnly, state.failure == nil else { return false }
                state.resumeWaiter = continuation
                return true
            }
            if !waits { continuation.resume() }
        }
        try Task.checkCancellation()
    }

    /// Reads the first range as it arrives; returns the file's length.
    private func streamFirstRange(of url: URL) async throws -> Int {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(firstRange - 1)", forHTTPHeaderField: "Range")
        let receiver = RangeReceiver { [weak self] data in
            guard let self else { return }
            self.work.async { self.feed(data) }
        }
        let response = try await receiver.run(request, in: Self.session)
        if response.statusCode == 200 {
            // The whole file came in this one answer.
            return 0
        }
        guard response.statusCode == 206,
              let total = response.value(forHTTPHeaderField: "Content-Range")?
                .split(separator: "/").last.flatMap({ Int($0) }) else { throw StreamError.badResponse }
        return total
    }

    /// The rest in 1 MB ranges, four at a time, handed to the parser in order.
    private func fetchRest(of url: URL, from start: Int, total: Int) async throws {
        let offsets = Array(stride(from: start, to: total, by: Self.rangeSize))
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var pending = offsets.makeIterator()
            for _ in 0..<Self.parallelRequests {
                guard let offset = pending.next() else { break }
                group.addTask {
                    let data = try await Self.range(url, offset, min(offset + Self.rangeSize, total))
                    return (offset, data)
                }
            }
            var ready: [Int: Data] = [:]
            var next = start
            while let result = try await group.next() {
                ready[result.0] = result.1
                while let data = ready.removeValue(forKey: next) {
                    work.async { self.feed(data) }
                    next += data.count
                }
                if let offset = pending.next() {
                    group.addTask {
                        let data = try await Self.range(url, offset, min(offset + Self.rangeSize, total))
                        return (offset, data)
                    }
                }
            }
        }
    }

    /// One range, tried up to three times.
    private static func range(_ url: URL, _ start: Int, _ end: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 206, data.count == end - start else {
                    throw StreamError.badResponse
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                if attempt >= 3 { throw error }
                try await Task.sleep(for: .milliseconds(300 * attempt))
            }
        }
    }

    /// One session for every stream, so the connection to YouTube's audio servers is reused.
    fileprivate static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration, delegate: SessionDispatcher.shared, delegateQueue: nil)
    }()

    // MARK: Decoding (on `work`)

    private func feed(_ data: Data) {
        guard withState({ $0.failure == nil && !$0.finished }) else { return }
        do {
            let now = ProcessInfo.processInfo.systemUptime
            withState { state in
                if state.timing.firstByte == nil { state.timing.firstByte = now }
            }
            let packets = try parser.append(data)
            if parser.headIsComplete {
                withState { state in
                    if state.timing.head == nil { state.timing.head = ProcessInfo.processInfo.systemUptime }
                }
            }
            guard !packets.isEmpty else { return }
            if decoder == nil { try open(first: packets[0].data) }
            guard let decoder else { return }
            write(try decoder.decode(packets.map(\.data), final: false))
        } catch {
            fail(error)
        }
    }

    /// The decoder and the file, with the length the WAV declares.
    private func open(first packet: Data) throws {
        let head = parser.head
        let channels = max(1, min(head.channels, 2))
        decoder = try OpusPacketDecoder(channels: channels, preSkip: head.preSkip,
                                        framesPerPacket: WebMStreamParser.framesPerPacket(packet))
        let duration = head.duration ?? fallbackDuration ?? 0
        let frames = max(0, Int((duration * Double(Self.sampleRate)).rounded()) - head.preSkip)
        FileManager.default.createFile(atPath: file.path, contents: Self.header(frames: frames, channels: channels))
        writer = try FileHandle(forWritingTo: file)
        try writer?.seekToEnd()
        withState { state in
            state.channels = channels
            state.declaredFrames = frames
        }
        dataAvailable()
    }

    private func write(_ pcm: Data) {
        guard !pcm.isEmpty, let writer else { return }
        do {
            try writer.write(contentsOf: pcm)
        } catch {
            fail(error)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let ready = withState { state -> [CheckedContinuation<Void, Error>] in
            if state.timing.firstAudio == nil { state.timing.firstAudio = now }
            state.decodedBytes += pcm.count
            let bytes = state.decodedBytes
            let ready = state.audioWaiters.filter { $0.bytes <= bytes }.map(\.continuation)
            state.audioWaiters.removeAll { $0.bytes <= bytes }
            return ready
        }
        ready.forEach { $0.resume() }
        dataAvailable()
    }

    private func finish() {
        guard withState({ $0.failure == nil && !$0.finished }) else { return }
        do {
            guard let decoder else { throw WebMStreamParser.ParseError.notOpus }
            write(try decoder.decode([], final: true))
            guard withState({ $0.failure == nil }) else { return }
            // The header with the real length, then the file where it is kept.
            let (channels, bytes) = withState { ($0.channels, $0.decodedBytes) }
            try writer?.seek(toOffset: 0)
            try writer?.write(contentsOf: Self.header(frames: bytes / (2 * channels), channels: channels))
            try writer?.close()
            writer = nil
            var completed = file
            if let destination {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file, to: destination)
                completed = destination
            }
            let now = ProcessInfo.processInfo.systemUptime
            let waiters = withState { state -> ([CheckedContinuation<URL, Error>], [CheckedContinuation<Void, Error>]) in
                state.finished = true
                state.completed = completed
                state.timing.completed = now
                defer {
                    state.completionWaiters = []
                    state.audioWaiters = []
                }
                return (state.completionWaiters, state.audioWaiters.map(\.continuation))
            }
            waiters.0.forEach { $0.resume(returning: completed) }
            waiters.1.forEach { $0.resume() }
            dataAvailable()
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        let waiters = withState { state -> ([CheckedContinuation<URL, Error>], [CheckedContinuation<Void, Error>],
                                           CheckedContinuation<Void, Error>?)? in
            guard state.failure == nil, state.completed == nil else { return nil }
            state.failure = error
            defer {
                state.completionWaiters = []
                state.audioWaiters = []
                state.resumeWaiter = nil
            }
            return (state.completionWaiters, state.audioWaiters.map(\.continuation), state.resumeWaiter)
        }
        guard let waiters else { return }
        network?.cancel()
        try? writer?.close()
        writer = nil
        try? FileManager.default.removeItem(at: file)
        waiters.0.forEach { $0.resume(throwing: error) }
        waiters.1.forEach { $0.resume(throwing: error) }
        waiters.2?.resume(throwing: error)
        dataAvailable()
    }

    /// A canonical 44-byte WAV header: 16-bit PCM at 48 kHz.
    private static func header(frames: Int, channels: Int) -> Data {
        let blockAlign = 2 * channels
        let dataSize = UInt32(clamping: frames * blockAlign)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(clamping: 36 + Int(dataSize)))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * blockAlign))
        append(UInt16(blockAlign))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        return data
    }

    // MARK: Serving (on `loaderQueue`)

    private func dataAvailable() {
        loaderQueue.async { self.serve() }
    }

    private func serve() {
        let snapshot = withState { ($0.declaredFrames, $0.channels, $0.decodedBytes, $0.finished, $0.failure) }
        let (declared, channels, decoded, finished, failure) = snapshot
        requests.removeAll { request in
            if request.isCancelled || request.isFinished { return true }
            if let failure {
                request.finishLoading(with: failure)
                return true
            }
            // The length is known with the first packets.
            guard let declared else { return false }
            let dataSize = declared * 2 * channels
            let total = Self.headerSize + dataSize
            if let information = request.contentInformationRequest {
                information.contentType = AVFileType.wav.rawValue
                information.contentLength = Int64(total)
                information.isByteRangeAccessSupported = true
            }
            guard let dataRequest = request.dataRequest else {
                request.finishLoading()
                return true
            }
            let end = dataRequest.requestsAllDataToEndOfResource
                ? total : min(total, Int(dataRequest.requestedOffset) + dataRequest.requestedLength)
            var offset = Int(dataRequest.currentOffset)
            while offset < end, let piece = bytes(at: offset, upTo: min(end, offset + (512 << 10)),
                                                  declared: declared, channels: channels,
                                                  decoded: decoded, finished: finished) {
                dataRequest.respond(with: piece)
                offset += piece.count
            }
            if offset >= end {
                request.finishLoading()
                return true
            }
            return false
        }
    }

    /// The WAV's bytes from `offset`: the header, then the PCM decoded so far (silence past the
    /// end of a song shorter than it said). Nil while they aren't decoded yet.
    private func bytes(at offset: Int, upTo end: Int, declared: Int, channels: Int, decoded: Int, finished: Bool) -> Data? {
        if offset < Self.headerSize {
            return Self.header(frames: declared, channels: channels).subdata(in: offset..<min(Self.headerSize, end))
        }
        let position = offset - Self.headerSize
        if position < decoded {
            let count = min(end - offset, decoded - position)
            do {
                // The file moves where it is kept once complete (an open reader follows it).
                if reader == nil { reader = try FileHandle(forReadingFrom: completedURL ?? file) }
                try reader?.seek(toOffset: UInt64(offset))
                guard let data = try reader?.read(upToCount: count), !data.isEmpty else { return nil }
                return data
            } catch {
                return nil
            }
        }
        guard finished else { return nil }
        return Data(count: end - offset)
    }
}

extension OpusStream: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url == playbackURL else { return false }
        requests.append(loadingRequest)
        serve()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        requests.removeAll { $0 === loadingRequest }
    }
}

/// Hands each streaming task's callbacks to its `RangeReceiver`.
private final class SessionDispatcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = SessionDispatcher()
    private let lock = NSLock()
    private var receivers: [Int: RangeReceiver] = [:]

    func register(_ receiver: RangeReceiver, for task: URLSessionTask) {
        lock.lock()
        receivers[task.taskIdentifier] = receiver
        lock.unlock()
    }

    private func receiver(for task: URLSessionTask, removing: Bool = false) -> RangeReceiver? {
        lock.lock()
        defer { lock.unlock() }
        return removing ? receivers.removeValue(forKey: task.taskIdentifier) : receivers[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let receiver = receiver(for: dataTask) else { return completionHandler(.allow) }
        receiver.received(response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receiver(for: dataTask)?.received(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        receiver(for: task, removing: true)?.completed(error)
    }
}

/// Reads one range, handing its bytes over as they arrive.
private final class RangeReceiver: @unchecked Sendable {
    private let onData: (Data) -> Void
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var cancelled = false
    private var rejected = false

    init(onData: @escaping (Data) -> Void) {
        self.onData = onData
    }

    func run(_ request: URLRequest, in session: URLSession) async throws -> HTTPURLResponse {
        let task = session.dataTask(with: request)
        SessionDispatcher.shared.register(self, for: task)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: {
            self.cancelled = true
            task.cancel()
        }
    }

    // On the session's delegate queue, one at a time.
    func received(_ response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
            rejected = true
            completionHandler(.cancel)
            return
        }
        self.response = http
        completionHandler(.allow)
    }

    func received(_ data: Data) {
        onData(data)
    }

    func completed(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else if rejected {
            continuation.resume(throwing: OpusStream.StreamError.badResponse)
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response {
            continuation.resume(returning: response)
        } else {
            continuation.resume(throwing: OpusStream.StreamError.badResponse)
        }
    }
}

/// Decodes Opus packets as they come with Apple's decoder, into interleaved 16-bit PCM at
/// 48 kHz, leaving out the encoder's delay ("pre-skip") at the start.
final class OpusPacketDecoder {
    private let converter: AVAudioConverter
    private let opusFormat: AVAudioFormat
    private let pcmFormat: AVAudioFormat
    private let channels: Int
    private var pending: [Data] = []
    private var framesToSkip: Int
    private var ended = false

    init(channels: Int, preSkip: Int, framesPerPacket: UInt32) throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard let opusFormat = AVAudioFormat(streamDescription: &description),
              let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                            channels: AVAudioChannelCount(channels), interleaved: true),
              let converter = AVAudioConverter(from: opusFormat, to: pcmFormat) else {
            throw OpusStream.StreamError.decoderUnavailable
        }
        self.opusFormat = opusFormat
        self.pcmFormat = pcmFormat
        self.converter = converter
        self.channels = channels
        framesToSkip = preSkip
    }

    /// The PCM of `packets` (and of what the decoder still held, when `final`).
    func decode(_ packets: [Data], final: Bool) throws -> Data {
        guard !ended else { return Data() }
        pending.append(contentsOf: packets)
        var pcm = Data()
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 9_600) else {
                throw OpusStream.StreamError.decoderUnavailable
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard !self.pending.isEmpty else {
                    inputStatus.pointee = final ? .endOfStream : .noDataNow
                    return nil
                }
                let batch = self.pending.prefix(64)
                self.pending.removeFirst(batch.count)
                let largest = batch.map(\.count).max() ?? 0
                let buffer = AVAudioCompressedBuffer(format: self.opusFormat, packetCapacity: AVAudioPacketCount(batch.count),
                                                     maximumPacketSize: largest)
                var offset = 0
                for (position, packet) in batch.enumerated() {
                    packet.withUnsafeBytes { raw in
                        if let base = raw.baseAddress {
                            buffer.data.advanced(by: offset).copyMemory(from: base, byteCount: packet.count)
                        }
                    }
                    buffer.packetDescriptions?[position] = AudioStreamPacketDescription(
                        mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
                    offset += packet.count
                }
                buffer.packetCount = AVAudioPacketCount(batch.count)
                buffer.byteLength = UInt32(offset)
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error { throw conversionError ?? OpusStream.StreamError.decoderUnavailable }
            append(output, to: &pcm)
            switch status {
            case .haveData:
                continue
            case .endOfStream:
                ended = true
                return pcm
            default:
                // Ran dry: everything given so far is decoded.
                return pcm
            }
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, to pcm: inout Data) {
        var frames = Int(buffer.frameLength)
        guard frames > 0, let samples = buffer.int16ChannelData?[0] else { return }
        var first = 0
        if framesToSkip > 0 {
            first = min(framesToSkip, frames)
            framesToSkip -= first
            frames -= first
        }
        guard frames > 0 else { return }
        pcm.append(UnsafeBufferPointer(start: samples + first * channels, count: frames * channels))
    }
}
