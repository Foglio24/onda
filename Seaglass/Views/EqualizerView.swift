import SwiftUI

/// Settings → Audio → Equalizzatore, also in the player's ··· menu: Spotify's presets, and a curve
/// whose six points can be dragged to make your own.
struct EqualizerView: View {
    @ObservedObject private var equalizer = Equalizer.shared

    private var presets: [EqualizerPreset] {
        // "Personalizzato" once there is a curve of your own to go back to.
        let hasCustom = equalizer.preset == .custom || equalizer.customGains.contains { $0 != 0 }
        return EqualizerPreset.allCases.filter { $0 != .custom || hasCustom }
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $equalizer.isOn) {
                    Label("Equalizzatore", systemImage: "slider.vertical.3")
                }
            } footer: {
                Text("Vale per tutti i brani, in streaming e scaricati, anche in karaoke. Quando un preset alza delle frequenze, il volume generale scende di quanto serve perché il suono non distorca.")
            }

            Section {
                EqualizerCurve(gains: equalizer.gains, isOn: equalizer.isOn) { band, gain in
                    equalizer.setGain(gain, band: band)
                }
                .frame(height: 230)
                .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 8, trailing: 8))
            } header: {
                Text(equalizer.preset.title)
            } footer: {
                Text("Trascina un punto in su o in giù per creare il tuo equalizzatore.")
            }

            Section("Preset") {
                ForEach(presets) { preset in
                    Button {
                        equalizer.select(preset)
                    } label: {
                        HStack {
                            Text(preset.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if preset == equalizer.preset {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { AmbientBackground() }
        .navigationTitle("Equalizzatore")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The six bands as points on a smooth line over a ±12 dB grid, like Spotify's equalizer.
/// Dragging anywhere in a band's column moves its point.
private struct EqualizerCurve: View {
    let gains: [Float]
    let isOn: Bool
    let onChange: (Int, Float) -> Void

    @State private var activeBand: Int?

    private let labelHeight: CGFloat = 26
    private let inset: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let plot = CGSize(width: geometry.size.width - inset * 2, height: geometry.size.height - labelHeight)
            let points = gains.indices.map { point(band: $0, in: plot) }
            ZStack(alignment: .topLeading) {
                grid(plot)
                fill(points, plot: plot)
                    .fill(isOn ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(Color.secondary.opacity(0.08)))
                curve(points)
                    .stroke(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                ForEach(points.indices, id: \.self) { band in
                    Circle()
                        .fill(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                        .overlay { Circle().stroke(.background, lineWidth: 2) }
                        .frame(width: activeBand == band ? 22 : 16, height: activeBand == band ? 22 : 16)
                        .position(points[band])
                        .animation(.spring(duration: 0.25), value: activeBand)
                    Text(EqualizerBands.labels[band])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: points[band].x, y: plot.height + labelHeight / 2 + 2)
                }
                if let activeBand {
                    Text(Self.decibels(gains[activeBand]))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                        .position(x: points[activeBand].x, y: max(12, points[activeBand].y - 26))
                }
            }
            .contentShape(.rect)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let band = activeBand ?? nearestBand(to: value.startLocation.x, width: plot.width)
                        activeBand = band
                        onChange(band, gain(at: value.location.y, height: plot.height))
                    }
                    .onEnded { _ in activeBand = nil }
            )
            .sensoryFeedback(.selection, trigger: activeBand.map { gains[$0] })
        }
    }

    private static func decibels(_ gain: Float) -> String {
        Double(gain).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + " dB"
    }

    private func point(band: Int, in plot: CGSize) -> CGPoint {
        let x = inset + plot.width * CGFloat(band) / CGFloat(EqualizerBands.count - 1)
        return CGPoint(x: x, y: y(for: gains[band], height: plot.height))
    }

    /// +12 dB at the top, -12 dB at the bottom, with room for the points.
    private func y(for gain: Float, height: CGFloat) -> CGFloat {
        let half = height / 2 - 12
        return height / 2 - CGFloat(gain / EqualizerBands.limit) * half
    }

    private func gain(at y: CGFloat, height: CGFloat) -> Float {
        let half = height / 2 - 12
        return Float((height / 2 - y) / half) * EqualizerBands.limit
    }

    private func nearestBand(to x: CGFloat, width: CGFloat) -> Int {
        let step = width / CGFloat(EqualizerBands.count - 1)
        return max(0, min(EqualizerBands.count - 1, Int(((x - inset) / step).rounded())))
    }

    private func grid(_ plot: CGSize) -> some View {
        Path { path in
            for gain: Float in [EqualizerBands.limit, 0, -EqualizerBands.limit] {
                let y = self.y(for: gain, height: plot.height)
                path.move(to: CGPoint(x: inset, y: y))
                path.addLine(to: CGPoint(x: inset + plot.width, y: y))
            }
        }
        .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    /// A Catmull-Rom spline through the points, drawn as cubic Béziers.
    private func curve(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for index in 0..<(points.count - 1) {
                let p0 = points[max(index - 1, 0)], p1 = points[index]
                let p2 = points[index + 1], p3 = points[min(index + 2, points.count - 1)]
                let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: control1, control2: control2)
            }
        }
    }

    private func fill(_ points: [CGPoint], plot: CGSize) -> Path {
        var path = curve(points)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: plot.height))
        path.addLine(to: CGPoint(x: first.x, y: plot.height))
        path.closeSubpath()
        return path
    }
}
