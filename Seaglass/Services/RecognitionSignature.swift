import AVFoundation
import ShazamKit

/// ShazamKit is used only for local fingerprints. No SHSession or catalog service is requested.
enum RecognitionSignature {
    struct Payload: Sendable {
        let data: Data
        let duration: TimeInterval
    }

    enum Failure: LocalizedError {
        case invalidAudio, unsupportedSignature
        var errorDescription: String? {
            String(localized: "Impossibile creare l’impronta audio. Riprova ad ascoltare il brano.")
        }
    }

    static func make(from sample: URL) async throws -> Payload {
        let work = Task.detached(priority: .userInitiated) { try generate(from: sample) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    static func generate(from sample: URL) throws -> Payload {
        guard sample.isFileURL,
              let size = try? sample.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 10_000_000 else { throw Failure.invalidAudio }
        let file = try AVAudioFile(forReading: sample)
        let rate = file.processingFormat.sampleRate
        let duration = rate > 0 ? Double(file.length) / rate : 0
        guard duration.isFinite, duration > 0, duration <= 12,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            throw Failure.invalidAudio
        }
        let generator = SHSignatureGenerator()
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            guard buffer.frameLength > 0 else { break }
            try generator.append(buffer, at: nil)
        }
        try Task.checkCancellation()
        let signature = generator.signature()
        return Payload(data: try wireData(from: signature.dataRepresentation), duration: duration)
    }

    /// Apple may wrap its raw signature when serializing it. Accept only a bounded, recognized
    /// wire packet with an exact embedded length; unknown OS formats fail instead of sending audio.
    static func wireData(from representation: Data) throws -> Data {
        guard representation.count >= 56, representation.count <= 262_144 else { throw Failure.unsupportedSignature }
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(representation[offset + $1]) << (8 * $1) }
        }
        for offset in stride(from: 0, through: min(64, representation.count - 48), by: 4) {
            let magic = word(offset)
            guard magic == 0xcafe2580 || magic == 0xb8709880 else { continue }
            let bodyLength = Int(word(offset + 8))
            guard bodyLength > 0, bodyLength + 48 == representation.count - offset else { continue }
            return Data(representation.dropFirst(offset))
        }
        throw Failure.unsupportedSignature
    }
}
