import Foundation

/// Comparing version names like "1.1" and "v1.10.2" (used by Check for Updates).
enum Version {
    /// The numbers in a version name: "v1.10.2" gives [1, 10, 2]. A leading "v" and anything
    /// that isn't a number are ignored.
    static func parts(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// Whether `candidate` is a later version than `current` ("1.10" is newer than "1.9").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        guard !a.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
