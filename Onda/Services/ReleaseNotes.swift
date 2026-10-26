import Foundation

/// Version numbers as the app and GitHub tags write them ("1.5.0", "v1.5.0").
enum AppVersion {
    static func components(_ version: String) -> [Int] {
        version.trimmingCharacters(in: .whitespaces)
            .drop { $0 == "v" || $0 == "V" }
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// True when `candidate` is a later version than `current` ("1.10.0" is later than "1.9.2").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = components(candidate)
        let old = components(current)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// A release body from GitHub (Markdown), split into the blocks the update sheet shows.
enum ReleaseNoteBlock: Equatable {
    case heading(String)
    /// `level` 0 for top-level items, 1 for items nested under them, and so on.
    case bullet(String, level: Int)
    case paragraph(String)

    static func parse(_ markdown: String) -> [ReleaseNoteBlock] {
        markdown.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("#") {
                return .heading(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let indent = line.prefix { $0 == " " }.count
                return .bullet(String(trimmed.dropFirst(2)), level: min(indent / 2, 3))
            }
            return .paragraph(trimmed)
        }
    }
}
