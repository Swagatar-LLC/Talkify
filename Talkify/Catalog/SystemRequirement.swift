import Foundation

/// Whether this Mac's system can run a Catalog Model, from the catalog's dotted version.
///
/// Catalog Models need macOS 26.7 or later, past the Core ML parser fix. The running
/// version is passed in, never read here, so the older-system path can be tested on any Mac.
enum SystemRequirement {
  /// Missing components count as zero, so "26.7" is 26.7.0. An unreadable string is
  /// never satisfied: a catalog typo must not unlock a model on an unpatched system.
  static func isSatisfied(minimum: String, by version: OperatingSystemVersion) -> Bool {
    guard let required = parse(minimum) else { return false }
    let running = [version.majorVersion, version.minorVersion, version.patchVersion]
    return !running.lexicographicallyPrecedes(required)
  }

  static func parse(_ dotted: String) -> [Int]? {
    let parts = dotted.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
    return parts.compactMap(\.self) + Array(repeating: 0, count: 3 - parts.count)
  }

  static func describe(_ version: OperatingSystemVersion) -> String {
    let base = "\(version.majorVersion).\(version.minorVersion)"
    return version.patchVersion == 0 ? base : base + ".\(version.patchVersion)"
  }
}
