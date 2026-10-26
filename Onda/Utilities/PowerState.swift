import Foundation

/// Whether the iPhone is warm or in Low Power Mode. Work that only prepares songs that may never
/// be played (unlocking the links of songs on screen, caching the song after next, karaoke ahead
/// of time) waits then, as Apple recommends from the "fair" thermal state up.
enum PowerState {
    static var isConstrained: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled
            || info.thermalState.rawValue >= ProcessInfo.ThermalState.fair.rawValue
    }
}
