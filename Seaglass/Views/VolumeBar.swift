import MediaPlayer
import SwiftUI

/// The volume under the player's controls, as in Apple Music: the system's own slider on iPhone and
/// iPad (it follows the buttons too), and on a Mac the volume of the sound output, the one in the
/// menu bar (through the AppKit plug-in, see `MacBridge`).
struct PlayerVolumeBar: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            if ProcessInfo.processInfo.isMacCatalystApp {
                MacVolumeSlider()
            } else {
                SystemVolumeSlider()
                    .frame(height: 30)
            }
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(Color.white.opacity(0.6))
        // Quiet on the left in every language, as the system's.
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// iOS's volume slider (`MPVolumeView`), white on the player with a small knob.
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.setVolumeThumbImage(Self.knob, for: .normal)
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        }
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}

    private static let knob = UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { context in
        UIColor.white.setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 14, height: 14))
    }
}

/// The Mac's output volume, followed while the player shows it.
@MainActor
final class MacVolume: ObservableObject {
    static let shared = MacVolume()

    @Published private(set) var value: Double = 0.5
    /// False when the output has no volume to set (some HDMI and USB outputs).
    @Published private(set) var available = false
    /// While the knob is dragged, the changes it makes come back and mustn't move it.
    var dragging = false
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MacBridge.shared.observeVolume { [weak self] volume in
            guard let self else { return }
            available = volume != nil
            if let volume, !dragging { value = Double(volume) }
        }
    }

    func set(_ volume: Double) {
        value = volume
        MacBridge.shared.setSystemVolume(Float(volume))
    }
}

/// The Mac's volume as Apple Music shows it in its corner and its player bar: the slider, then the
/// speaker (its waves following the level).
struct MacVolumeControl: View {
    var tint: Color = .white
    @ObservedObject private var volume = MacVolume.shared

    var body: some View {
        HStack(spacing: 8) {
            MacVolumeSlider(tint: tint)
            Image(systemName: "speaker.wave.3.fill", variableValue: volume.value)
                .font(.caption)
                .foregroundStyle(tint.opacity(0.8))
        }
    }
}

/// The volume's bar, drawn here rather than a `Slider`: in the player and the player bar the
/// system's slider lost its drags to the glass around it, as the scrubber did (see `PlayerScrubber`).
/// A click sets the volume where it lands, and a drag follows the pointer.
private struct MacVolumeSlider: View {
    var tint: Color = .white
    @ObservedObject private var volume = MacVolume.shared

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let knob: CGFloat = 12
            let x = (width - knob) * CGFloat(volume.value)
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.25)).frame(height: 4)
                Capsule().fill(tint).frame(width: x + knob / 2, height: 4)
                Circle()
                    .fill(tint)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: x)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        volume.dragging = true
                        volume.set(Double(min(max((value.location.x - knob / 2) / (width - knob), 0), 1)))
                    }
                    .onEnded { _ in volume.dragging = false }
            )
        }
        .frame(height: 20)
        .opacity(volume.available ? 1 : 0.4)
        .allowsHitTesting(volume.available)
        .accessibilityElement()
        .accessibilityLabel(Text("Volume"))
        .accessibilityValue(Text(volume.value.formatted(.percent.precision(.fractionLength(0)))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume.set(min(1, volume.value + 0.0625))
            case .decrement: volume.set(max(0, volume.value - 0.0625))
            @unknown default: break
            }
        }
        .onAppear { volume.start() }
    }
}
