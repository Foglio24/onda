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

private struct MacVolumeSlider: View {
    @ObservedObject private var volume = MacVolume.shared

    var body: some View {
        Slider(value: Binding(get: { volume.value }, set: { volume.set($0) }), in: 0...1) { editing in
            volume.dragging = editing
        }
        .tint(.white)
        .disabled(!volume.available)
        .accessibilityLabel(Text("Volume"))
        .onAppear { volume.start() }
    }
}
