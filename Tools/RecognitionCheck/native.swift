import AVFoundation
import ShazamKit

@main struct NativeRecognitionCheck {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() async throws {
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--live" {
            let original = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
            let sample = FileManager.default.temporaryDirectory.appending(path: "recognition-live-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: sample) }
            let frames = AVAudioFrameCount(min(Double(original.length), original.processingFormat.sampleRate * 10))
            guard let clip = AVAudioPCMBuffer(pcmFormat: original.processingFormat, frameCapacity: frames) else {
                throw RecognitionSignature.Failure.invalidAudio
            }
            try original.read(into: clip, frameCount: frames)
            do {
                let output = try AVAudioFile(forWriting: sample, settings: original.processingFormat.settings)
                try output.write(from: clip)
            }
            let payload = try await RecognitionSignature.make(from: sample)
            // Exactly one recognition request. Refusal, throttling and no-match are failures;
            // there is no retry, alternate identity, service token or official-app header.
            guard let result = try await RecognitionAPI.recognize(signature: payload.data, sampleDuration: payload.duration) else {
                fputs("Native recognition returned no match\n", stderr)
                exit(1)
            }
            print("NativeRecognitionCheck: matched \(result.title) — \(result.artist), \(payload.duration)s signature (\(payload.data.count) bytes)")
            expect(result.title.localizedCaseInsensitiveContains("Warriors"), "known public fixture must match Warriors")
            return
        }
        let reference = try Data(contentsOf: URL(fileURLWithPath: "Tools/RecognitionCheck/reference.sig"))
        let imported = try SHSignature(dataRepresentation: reference)
        let roundTrip = try RecognitionSignature.wireData(from: imported.dataRepresentation)
        expect(roundTrip == reference, "a valid community wire signature survives Apple's import/export")
        expect(imported.duration > 0 && imported.duration <= 12.1, "reference sample has a bounded duration")

        let file = FileManager.default.temporaryDirectory.appending(path: "recognition-native-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441_000),
              let channel = buffer.floatChannelData?[0] else { throw RecognitionSignature.Failure.invalidAudio }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            channel[index] = Float(0.15 * sin(Double(index) * 2 * .pi * 440 / 44_100))
        }
        do {
            let audio = try AVAudioFile(forWriting: file, settings: format.settings)
            try audio.write(from: buffer)
        }
        let generated = try await RecognitionSignature.make(from: file)
        expect(generated.duration == 10, "native sample duration is retained")
        let native = try SHSignature(dataRepresentation: generated.data)
        expect(native.duration > 0, "generated raw wire signature imports without any catalog service")
        let exported = try RecognitionSignature.wireData(from: native.dataRepresentation)
        expect(exported == generated.data, "native wire signature roundtrip preserves fingerprint bytes")
        do {
            _ = try RecognitionSignature.wireData(from: Data(repeating: 0, count: 80))
            expect(false, "unknown serialization formats must fail closed")
        } catch is RecognitionSignature.Failure { }
        print("NativeRecognitionCheck: local generation, import/export and wire normalization passed (\(generated.data.count) bytes)")
    }
}
