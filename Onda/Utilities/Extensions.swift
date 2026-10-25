import Foundation

extension TimeInterval {
    /// "3:07" or "1:02:45".
    var formattedTime: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// Lets a URL drive `.sheet(item:)`.
struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}
