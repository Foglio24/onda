import Foundation

/// Tiny helpers for digging through loosely typed JSON (InnerTube and Last.fm responses).
enum J {
    /// Follows a path of dictionary keys (`String`) and array positions (`Int`).
    static func value(_ root: Any?, _ path: Any...) -> Any? {
        var current = root
        for component in path {
            switch component {
            case let key as String:
                current = (current as? [String: Any])?[key]
            case let position as Int:
                guard let array = current as? [Any], array.indices.contains(position) else { return nil }
                current = array[position]
            default:
                return nil
            }
        }
        return current
    }

    static func string(_ value: Any?) -> String? { value as? String }
    static func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    static func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    /// Calls `visit` on every object below `root`, parents before children. Array order is preserved.
    static func walk(_ root: Any?, _ visit: ([String: Any]) -> Void) {
        if let object = root as? [String: Any] {
            visit(object)
            for (_, child) in object { walk(child, visit) }
        } else if let array = root as? [Any] {
            for child in array { walk(child, visit) }
        }
    }

    /// Every object stored under `key` anywhere below `root`. Array order is preserved.
    static func findAll(_ key: String, in root: Any?) -> [[String: Any]] {
        var results: [[String: Any]] = []
        func walk(_ node: Any?) {
            if let object = node as? [String: Any] {
                for (name, child) in object {
                    if name == key, let match = child as? [String: Any] {
                        results.append(match)
                    } else {
                        walk(child)
                    }
                }
            } else if let array = node as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(root)
        return results
    }
}
