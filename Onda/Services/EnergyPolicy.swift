import Foundation

/// The same budget is used by audio preparation, AI work and visual effects.
/// Normal playback and already prepared files remain usable at every thermal level.
struct EnergyBudget {
    let thermalState: ProcessInfo.ThermalState
    let lowPowerMode: Bool

    var allowsSpeculativeWork: Bool {
        !lowPowerMode && thermalState == .nominal
    }

    var allowsMotionEffects: Bool { allowsSpeculativeWork }

    /// A requested conversion may finish while slightly warm, but expensive work
    /// must stop when iOS starts reducing performance or Low Power Mode is enabled.
    var allowsAudioConversion: Bool {
        guard !lowPowerMode else { return false }
        switch thermalState {
        case .nominal, .fair: return true
        case .serious, .critical: return false
        @unknown default: return false
        }
    }

    var allowsKaraoke: Bool { allowsAudioConversion }
}

enum EnergyPolicy {
    static var current: EnergyBudget {
        let process = ProcessInfo.processInfo
        let lowPower: Bool
        if #available(iOS 9, macOS 12, *) {
            lowPower = process.isLowPowerModeEnabled
        } else {
            lowPower = false
        }
        return EnergyBudget(thermalState: process.thermalState, lowPowerMode: lowPower)
    }
}
