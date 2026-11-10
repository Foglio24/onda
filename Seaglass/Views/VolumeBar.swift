import MediaPlayer
import SwiftUI

/// The volume under the player's controls, as in Apple Music: the system's own slider on iPhone and
/// iPad (it follows the buttons too), and the app's own volume on a Mac.
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

/// The Mac's volume as Apple Music shows it in its corner and its player bar: the slider, then the
/// speaker (its waves following the level).
struct MacVolumeControl: View {
    var tint: Color = .white
    @ObservedObject private var volume = PlaybackVolume.shared

    var body: some View {
        HStack(spacing: 8) {
            MacVolumeSlider(tint: tint)
            Image(systemName: "speaker.wave.3.fill", variableValue: volume.value)
                .font(.caption)
                .foregroundStyle(tint.opacity(0.8))
        }
    }
}

/// The Mac's own slider (a `UISlider` that behaves as macOS's): it takes the pointer as a control,
/// where a bar drawn in SwiftUI lost its drags to the glass around it, and at times to the window,
/// which moved instead.
private struct MacVolumeSlider: UIViewRepresentable {
    var tint: Color = .white
    @ObservedObject private var volume = PlaybackVolume.shared

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.preferredBehavioralStyle = .mac
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.accessibilityLabel = String(localized: "Volume")
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        if !slider.isTracking { slider.value = Float(volume.value) }
        slider.minimumTrackTintColor = UIColor(tint)
    }

    @MainActor
    final class Coordinator: NSObject {
        @objc func changed(_ slider: UISlider) {
            PlaybackVolume.shared.set(Double(slider.value), dragging: true)
        }
    }
}
