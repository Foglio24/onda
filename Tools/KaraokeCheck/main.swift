// Runs Seaglass's MDXSeparator (the app's own Swift code) on the fixture written by
// Tools/convert_karaoke_model.py and compares its vocals with onnxruntime's.
// CI builds and runs it on macOS before building the app:
//   swiftc -O Seaglass/Player/MDXSeparator.swift Tools/KaraokeCheck/main.swift -o karaoke-check
//   ./karaoke-check Generated/Karaoke/VocFT.mlmodelc Generated/karaoke-fixture.bin
import CoreML
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: karaoke-check <model.mlmodelc> <fixture.bin>")
    exit(2)
}
let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let frames = Int(data.withUnsafeBytes { $0.load(as: Int32.self) })
let samples: [Float] = data.dropFirst(4).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
guard samples.count == 4 * frames else {
    print("fixture has \(samples.count) samples, expected \(4 * frames)")
    exit(2)
}
let left = samples[0..<frames]
let right = samples[frames..<(2 * frames)]
let expectedLeft = Array(samples[(2 * frames)..<(3 * frames)])
let expectedRight = Array(samples[(3 * frames)..<(4 * frames)])

func rms(_ values: [Float]) -> Double {
    (values.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count))).squareRoot()
}
let mixRMS = rms(Array(left) + Array(right))

var failed = false
for (name, units) in [("cpuOnly", MLComputeUnits.cpuOnly), ("all", MLComputeUnits.all)] {
    do {
        let start = Date()
        let separator = try MDXSeparator(modelURL: URL(fileURLWithPath: arguments[1]), computeUnits: units)
        let loaded = Date()
        let vocals = try separator.vocals(left: left, right: right)
        let done = Date()
        let error = zip(vocals.left + vocals.right, expectedLeft + expectedRight).map { $0 - $1 }
        let relative = rms(error) / mixRMS
        let finite = (vocals.left + vocals.right).allSatisfy(\.isFinite)
        print(String(format: "%@: load %.1fs, piece %.2fs, vocals error %.1f dB below the mix, vocals rms %.4f (expected %.4f)",
                     name, loaded.timeIntervalSince(start), done.timeIntervalSince(loaded),
                     20 * log10(max(relative, 1e-12)), rms(vocals.left + vocals.right),
                     rms(expectedLeft + expectedRight)))
        if !finite || relative > 0.01 {
            print("\(name): the Swift separation does not match the reference")
            failed = true
        }
    } catch {
        print("\(name): \(error)")
        failed = failed || units == .cpuOnly
    }
}
exit(failed ? 1 : 0)
