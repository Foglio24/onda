import CoreMotion
import SwiftUI
import UIKit

/// Device tilt, smoothed, from -1 to 1 on each axis. Only runs while a view needs it and the app
/// is on screen, and not at all with Reduce Motion, in Low Power Mode or while the iPhone is hot.
@MainActor
final class MotionTilt: ObservableObject {
    static let shared = MotionTilt()

    @Published private(set) var pitch: Double = 0
    @Published private(set) var roll: Double = 0

    private let manager = CMMotionManager()
    private var users = 0
    private var isRunning = false
    private var inBackground = false
    /// Smoothed readings. They reach `pitch` and `roll` only when the change can be seen,
    /// so an iPhone held still (or lying on a table) redraws nothing.
    private var smoothPitch: Double = 0
    private var smoothRoll: Double = 0
    private static let visibleChange = 0.015
    private var observers: [NSObjectProtocol] = []

    private init() {
        inBackground = UIApplication.shared.applicationState == .background
        let center = NotificationCenter.default
        let updates: [(Notification.Name, Bool?)] = [
            (UIApplication.didEnterBackgroundNotification, true),
            (UIApplication.willEnterForegroundNotification, false),
            (UIAccessibility.reduceMotionStatusDidChangeNotification, nil),
            (.NSProcessInfoPowerStateDidChange, nil),
            (ProcessInfo.thermalStateDidChangeNotification, nil),
        ]
        observers = updates.map { name, background in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if let background { MotionTilt.shared.inBackground = background }
                    MotionTilt.shared.update()
                }
            }
        }
    }

    func start() {
        users += 1
        update()
    }

    func stop() {
        users = max(0, users - 1)
        update()
    }

    private var shouldRun: Bool {
        let info = ProcessInfo.processInfo
        return users > 0 && !inBackground && manager.isDeviceMotionAvailable
            && !UIAccessibility.isReduceMotionEnabled && !info.isLowPowerModeEnabled
            && info.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    private func update() {
        if shouldRun, !isRunning {
            isRunning = true
            manager.deviceMotionUpdateInterval = 1.0 / 30
            manager.startDeviceMotionUpdates(to: .main) { motion, _ in
                guard let motion else { return }
                // Measured from how a phone is usually held: tilted about 40° towards the face.
                let pitch = max(-1, min(1, (motion.attitude.pitch - 0.7) / 0.6))
                let roll = max(-1, min(1, motion.attitude.roll / 0.6))
                MainActor.assumeIsolated { MotionTilt.shared.apply(pitch: pitch, roll: roll) }
            }
        } else if !shouldRun, isRunning {
            isRunning = false
            manager.stopDeviceMotionUpdates()
            smoothPitch = 0
            smoothRoll = 0
            withAnimation(.smooth(duration: 0.5)) {
                pitch = 0
                roll = 0
            }
        }
    }

    private func apply(pitch: Double, roll: Double) {
        smoothPitch += (pitch - smoothPitch) * 0.2
        smoothRoll += (roll - smoothRoll) * 0.2
        if abs(smoothPitch - self.pitch) >= Self.visibleChange { self.pitch = smoothPitch }
        if abs(smoothRoll - self.roll) >= Self.visibleChange { self.roll = smoothRoll }
    }
}

/// The player's cover, like a physical sleeve in your hand: it tilts with the iPhone and with
/// the finger, a light reflection slides across it, and a double tap likes the song.
struct InteractiveArtwork: View {
    let track: Track?
    let isPlaying: Bool
    let onDoubleTap: () -> Void

    @ObservedObject private var motion = MotionTilt.shared
    @AppStorage(Preferences.interactiveArtwork) private var enabled = true
    @State private var drag: CGSize = .zero
    @State private var showsHeart = false

    var body: some View {
        // Degrees around the horizontal and vertical axes.
        let tiltX = enabled ? -motion.pitch * 8 - Double(drag.height) / 12 : 0
        let tiltY = enabled ? motion.roll * 10 + Double(drag.width) / 10 : 0
        let shift = CGFloat(tiltY / 30)

        ArtworkView(track: track, cornerRadius: 22, highRes: true)
            .overlay {
                if enabled {
                    LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.22), Color.white.opacity(0)],
                                   startPoint: UnitPoint(x: 0.3 - shift, y: 0),
                                   endPoint: UnitPoint(x: 0.9 - shift, y: 1))
                        .blendMode(.screen)
                        .clipShape(.rect(cornerRadius: 22))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                Image(systemName: "heart.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 12)
                    .scaleEffect(showsHeart ? 1 : 0.4)
                    .opacity(showsHeart ? 0.95 : 0)
                    .allowsHitTesting(false)
            }
            .rotation3DEffect(.degrees(tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .shadow(color: .black.opacity(0.45), radius: 30,
                    x: CGFloat(-tiltY * 1.5), y: CGFloat(16 + tiltX * 1.5))
            .scaleEffect(isPlaying ? 1 : 0.88)
            .animation(.spring(duration: 0.45, bounce: 0.25), value: isPlaying)
            .contentShape(.rect)
            .onTapGesture(count: 2) { like() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard enabled else { return }
                        // Mostly downwards: that drag closes the player (see NowPlayingView), so the
                        // cover stays flat instead of tilting along.
                        let translation = value.translation
                        if translation.height > 0, translation.height > abs(translation.width) {
                            if drag != .zero { withAnimation(.spring(duration: 0.3)) { drag = .zero } }
                            return
                        }
                        drag = CGSize(width: max(-120, min(120, translation.width)),
                                      height: max(-120, min(120, translation.height)))
                    }
                    .onEnded { _ in
                        withAnimation(.spring(duration: 0.6, bounce: 0.45)) { drag = .zero }
                    }
            )
            .onAppear { if enabled { motion.start() } }
            .onDisappear { if enabled { motion.stop() } }
            .onChange(of: enabled) { _, isOn in
                if isOn { motion.start() } else { motion.stop() }
            }
    }

    private func like() {
        onDoubleTap()
        withAnimation(.spring(duration: 0.35, bounce: 0.5)) { showsHeart = true }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.3)) { showsHeart = false }
        }
    }
}
