import Foundation

/// The rules every catalog entry must pass before it can merge, as a pure function.
///
/// `CatalogTests` runs it over the bundled file, so a pull request that pins a branch name,
/// an off-list host or a path that escapes the install folder fails the suite.
enum CatalogLint {
  /// Where catalog files may be fetched from.
  static let sourceHosts: Set<String> = ["huggingface.co"]
  /// Where a fetch may be redirected to: Hugging Face itself and its LFS CDN, which served
  /// `us.aws.cdn.hf.co` for the Whisper entry's weights.
  static let redirectHostSuffixes = [".huggingface.co", ".cdn.hf.co"]
  static let licences: Set<String> = ["MIT", "Apache-2.0", "CC-BY-4.0"]
  /// Formats Core ML parses in process (ADR-9001). Any other needs an XPC service with no
  /// network entitlement first, and Talkify has none yet.
  static let inProcessFormats: Set<CatalogModel.Format> = [.coreMLCompiled, .coreMLPackage]
  /// Catalog Models load only past the Core ML fix in macOS 26.7.
  static let minimumSystemVersion: [Int] = [26, 7]

  struct Violation: Equatable, Sendable, CustomStringConvertible {
    var modelID: String?
    var rule: Rule
    var detail: String

    var description: String { "\(modelID ?? "catalog"): \(rule) \(detail)" }
  }

  enum Rule: String, Equatable, Sendable {
    case schemaVersion
    case catalogVersion
    case duplicateID
    case emptyID
    case modelID
    case revision
    case host
    case https
    case urlTemplate
    case noFiles
    case path
    case duplicatePath
    case sha256
    case size
    case totalBytes
    case format
    case licence
    case minimumSystemVersion
    case availableNeedsMeasured
    case availableNeedsTwoReviewers
    case availableNeedsNetworkDenyTest
    case revokedNeedsReason
  }

  static func violations(in catalog: Catalog) -> [Violation] {
    var found: [Violation] = []
    if catalog.schemaVersion != 1 {
      found.append(Violation(rule: .schemaVersion, detail: "\(catalog.schemaVersion)"))
    }
    if catalog.catalogVersion < 1 {
      found.append(Violation(rule: .catalogVersion, detail: "\(catalog.catalogVersion)"))
    }
    var seen: Set<String> = []
    for model in catalog.models {
      if !seen.insert(model.id).inserted {
        found.append(Violation(modelID: model.id, rule: .duplicateID, detail: model.id))
      }
      found += violations(in: model)
    }
    return found
  }

  static func violations(in model: CatalogModel) -> [Violation] {
    var found: [Violation] = []
    func flag(_ rule: Rule, _ detail: String) {
      found.append(Violation(modelID: model.id, rule: rule, detail: detail))
    }

    if model.id.isEmpty {
      flag(.emptyID, "")
    } else if !isSlug(model.id) {
      flag(.modelID, model.id)
    }
    if model.sources.isEmpty { flag(.noFiles, "no sources") }
    for source in model.sources {
      if !isCommit(source.revision) { flag(.revision, source.revision) }
      if !sourceHosts.contains(source.host) { flag(.host, source.host) }
      for token in ["{repository}", "{revision}", "{path}"]
      where !source.urlTemplate.contains(token) {
        flag(.urlTemplate, "\(source.urlTemplate) lacks \(token)")
      }
      if source.files.isEmpty { flag(.noFiles, source.repository) }
      for file in source.files {
        guard let url = source.url(for: file) else {
          flag(.urlTemplate, file.path)
          continue
        }
        if url.scheme != "https" { flag(.https, url.absoluteString) }
        if url.host() != source.host { flag(.host, url.host() ?? url.absoluteString) }
      }
    }
    for mirror in model.mirrors where !mirror.urlTemplate.hasPrefix("https://") {
      flag(.https, mirror.urlTemplate)
    }

    for source in model.sources {
      if let folder = source.installFolder, !isContainedPath(folder) { flag(.path, folder) }
    }
    for file in model.files {
      if !isContainedPath(file.path) { flag(.path, file.path) }
      if !isSHA256(file.sha256) { flag(.sha256, "\(file.path) \(file.sha256)") }
      if file.size <= 0 { flag(.size, "\(file.path) \(file.size)") }
    }
    var paths: Set<String> = []
    for path in model.installPaths where !paths.insert(path.lowercased()).inserted {
      flag(.duplicatePath, path)
    }
    // A file cannot also be a folder another file sits in.
    for path in model.installPaths {
      let components = path.lowercased().split(separator: "/")
      for end in components.indices.dropLast() where paths.contains(components[...end].joined(separator: "/")) {
        flag(.duplicatePath, path)
        break
      }
    }
    let sum = model.files.reduce(Int64(0)) { $0 + $1.size }
    if sum != model.totalBytes { flag(.totalBytes, "declared \(model.totalBytes), files sum to \(sum)") }

    if !inProcessFormats.contains(model.format) { flag(.format, model.format.rawValue) }
    if !licences.contains(model.licence.spdx) { flag(.licence, model.licence.spdx) }
    if !meetsMinimumSystemVersion(model.minHardware.minimumSystemVersion) {
      flag(.minimumSystemVersion, model.minHardware.minimumSystemVersion)
    }

    if model.status == .available {
      if model.measured == nil { flag(.availableNeedsMeasured, "") }
      if !hasTwoReviewers(model.review) {
        flag(.availableNeedsTwoReviewers, "\(model.review?.reviewer ?? "-"), \(model.review?.secondReviewer ?? "-")")
      }
      if (model.review?.networkDenyTest ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
        flag(.availableNeedsNetworkDenyTest, "")
      }
    }
    if model.status == .revoked, model.revoked == nil { flag(.revokedNeedsReason, "") }
    return found
  }

  /// A full lowercase commit SHA-1: forty hex digits, never a branch or tag name.
  static func isCommit(_ revision: String) -> Bool {
    isLowercaseHex(revision, length: 40)
  }

  static func isSHA256(_ digest: String) -> Bool {
    isLowercaseHex(digest, length: 64)
  }

  /// Lowercase letters and digits in runs joined by single `-` or `.`, so an id can name the
  /// model's folder, which Delete removes whole, without ever reaching outside the root.
  static func isSlug(_ id: String) -> Bool {
    id.split(separator: "-", omittingEmptySubsequences: false)
      .flatMap { $0.split(separator: ".", omittingEmptySubsequences: false) }
      .allSatisfy { run in
        !run.isEmpty && run.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
      }
  }

  /// Relative, without `.` or `..` components, so it can never leave the install folder.
  static func isContainedPath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else {
      return false
    }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }

  static func isRedirectAllowed(to url: URL) -> Bool {
    guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
    return sourceHosts.contains(host) || redirectHostSuffixes.contains { host.hasSuffix($0) }
  }

  static func meetsMinimumSystemVersion(_ version: String) -> Bool {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return false }
    let numbers = parts.compactMap { $0 }
    let width = max(numbers.count, minimumSystemVersion.count)
    let padded = numbers + Array(repeating: 0, count: width - numbers.count)
    let floor = minimumSystemVersion + Array(repeating: 0, count: width - minimumSystemVersion.count)
    return !padded.lexicographicallyPrecedes(floor)
  }

  private static func hasTwoReviewers(_ review: CatalogModel.Review?) -> Bool {
    let first = review?.reviewer?.trimmingCharacters(in: .whitespaces) ?? ""
    let second = review?.secondReviewer?.trimmingCharacters(in: .whitespaces) ?? ""
    return !first.isEmpty && !second.isEmpty && first.lowercased() != second.lowercased()
  }

  private static func isLowercaseHex(_ text: String, length: Int) -> Bool {
    text.utf8.count == length && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
