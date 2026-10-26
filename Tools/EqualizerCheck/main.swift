// Checks the equalizer's filters: each band reaches its gain where it should, the presets stay in
// range, the preamp keeps boosts from clipping, and every filter is stable.
// Run from the repository root: bash Tools/EqualizerCheck/run.sh
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}

func close(_ value: Double, _ target: Double, within tolerance: Double) -> Bool {
    abs(value - target) <= tolerance
}

for sampleRate in [44_100.0, 48_000.0] {
    // Peaks reach their full gain at their own frequency.
    for band in 1...4 {
        let frequency = EqualizerBands.frequencies[band]
        for gain: Float in [-12, -6, 6, 12] {
            let response = EqualizerDesign.section(band: band, gain: gain, sampleRate: sampleRate)
                .response(at: frequency, sampleRate: sampleRate)
            expect(close(response, Double(gain), within: 0.01),
                   "\(Int(sampleRate)) Hz: \(Int(frequency)) Hz band at \(gain) dB gives \(String(format: "%.2f", response)) dB")
        }
    }
    // Shelves give half their gain at the corner and nearly all of it beyond.
    let low = EqualizerDesign.section(band: 0, gain: 8, sampleRate: sampleRate)
    expect(close(low.response(at: 60, sampleRate: sampleRate), 4, within: 0.05), "low shelf: half the gain at 60 Hz")
    expect(close(low.response(at: 15, sampleRate: sampleRate), 8, within: 0.4), "low shelf: full gain at 15 Hz")
    expect(close(low.response(at: 2_000, sampleRate: sampleRate), 0, within: 0.1), "low shelf: nothing at 2 kHz")
    let high = EqualizerDesign.section(band: 5, gain: -8, sampleRate: sampleRate)
    expect(close(high.response(at: 15_000, sampleRate: sampleRate), -4, within: 0.05), "high shelf: half the gain at 15 kHz")
    expect(close(high.response(at: 1_000, sampleRate: sampleRate), 0, within: 0.1), "high shelf: nothing at 1 kHz")

    // Every section of every preset is stable: both poles inside the unit circle.
    for preset in EqualizerPreset.allCases {
        guard let gains = preset.gains else { continue }
        for (band, gain) in gains.enumerated() {
            let filter = EqualizerDesign.section(band: band, gain: gain, sampleRate: sampleRate)
            let stable = abs(filter.a2) < 1 && abs(filter.a1) < 1 + filter.a2
            if !stable { expect(false, "\(preset.rawValue) band \(band) is unstable") }
        }
    }
}

// Flat changes nothing; a gain of 0 is no filter at all.
expect(EqualizerDesign.section(band: 2, gain: 0, sampleRate: 44_100) == .identity, "0 dB is no filter")
for frequency in [30.0, 250, 1_000, 8_000, 18_000] {
    let response = EqualizerDesign.response(gains: EqualizerPreset.flat.gains!, at: frequency)
    expect(close(response, 0, within: 0.001), "flat at \(Int(frequency)) Hz: \(response) dB")
}

// Presets: six bands within ±12 dB, and with the preamp no frequency goes above 0 dB by more
// than the overlap of neighbouring bands allows.
for preset in EqualizerPreset.allCases {
    guard let gains = preset.gains else {
        expect(preset == .custom, "only the custom preset has no gains")
        continue
    }
    expect(gains.count == EqualizerBands.count && gains.allSatisfy { abs($0) <= EqualizerBands.limit },
           "\(preset.rawValue): six gains within ±\(Int(EqualizerBands.limit)) dB")
    let peak = stride(from: 20.0, through: 20_000, by: 10).map {
        EqualizerDesign.response(gains: gains, at: $0)
    }.max() ?? 0
    expect(peak < 2.5, "\(preset.rawValue): loudest frequency \(String(format: "%+.2f", peak)) dB after the preamp")
}
expect(Set(EqualizerPreset.allCases.map(\.title)).count == EqualizerPreset.allCases.count, "preset names are distinct")

print(failures == 0 ? "EqualizerCheck: all checks passed" : "EqualizerCheck: \(failures) failed")
exit(failures == 0 ? 0 : 1)
