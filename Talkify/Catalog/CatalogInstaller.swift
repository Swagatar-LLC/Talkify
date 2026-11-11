import CryptoKit
import Foundation

/// Fetches a Catalog Model into Application Support, and proves before every load that the
/// files are still the bytes the bundled catalog pins.
///
/// Under `root`, one folder per model id:
/// - `<pin>.staging/` while downloading, removed on any failure or cancel;
/// - `<pin>/` once every file verifies, promoted by a single rename;
/// - `installed.json` naming the pin, revisions and catalog version installed.
///
/// `pin` is derived from every pinned path, size and digest, so a catalog update that changes
/// any byte names a new folder and an old install is never taken for the new one.
///
/// Nothing here touches the network except `install(_:progress:)`, which only the user's
/// Download starts. The hashes come from the catalog, never from the host.
struct CatalogInstaller: Sendable {
  let root: URL
  /// Core ML's compiled copy of whatever this app loads, purged on Delete. `nil` skips it.
  let compiledModelCache: URL?
  let catalogVersion: Int
  private let configuration: @Sendable () -> URLSessionConfiguration

  static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Talkify", directoryHint: .isDirectory)
      .appending(path: "Models", directoryHint: .isDirectory)
  }

  /// Where Core ML keeps what it compiled for the Neural Engine from this app's models. Measured
  /// with the Whisper turbo entry: 141 MB, and deleting it brings back the full ~3 minute
  /// first-load compile, so it is the compiled model itself and not a stale hint. Entries are
  /// keyed by opaque hashes, so it is purged whole; Talkify loads no other Core ML model.
  static var defaultCompiledModelCache: URL? {
    guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
    return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appending(path: bundleID, directoryHint: .isDirectory)
      .appending(path: "com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory)
  }

  /// Free space a download needs beyond the model itself, as a fraction of its size.
  static let spaceMargin = 1.2
  static let manifestName = "installed.json"

  init(
    root: URL = CatalogInstaller.defaultRoot,
    compiledModelCache: URL? = CatalogInstaller.defaultCompiledModelCache,
    catalogVersion: Int,
    configuration: @escaping @Sendable () -> URLSessionConfiguration = CatalogFetch.liveConfiguration
  ) {
    self.root = root
    self.compiledModelCache = compiledModelCache
    self.catalogVersion = catalogVersion
    self.configuration = configuration
  }

  func modelFolder(for model: CatalogModel) -> URL {
    root.appending(path: model.id, directoryHint: .isDirectory)
  }

  func installFolder(for model: CatalogModel) -> URL {
    modelFolder(for: model).appending(path: Self.pin(for: model), directoryHint: .isDirectory)
  }

  func stagingFolder(for model: CatalogModel) -> URL {
    modelFolder(for: model).appending(path: Self.pin(for: model) + ".staging", directoryHint: .isDirectory)
  }

  /// Downloads every pinned file, hashing as it writes, and promotes the model only once all
  /// of them match. `progress` reports bytes received so far across the whole model.
  @discardableResult
  func install(
    _ model: CatalogModel,
    progress: @escaping @Sendable (Int64) -> Void = { _ in }
  ) async throws -> URL {
    try refuseIfBlocked(model)
    let fileManager = FileManager.default
    let modelFolder = modelFolder(for: model)
    try fileManager.createDirectory(at: modelFolder, withIntermediateDirectories: true)
    try checkSpace(for: model, at: modelFolder)

    let staging = stagingFolder(for: model)
    // Left by a crash or a force quit mid-download; nothing in it was ever trusted.
    try? fileManager.removeItem(at: staging)
    do {
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
      let configuration = configuration()
      var received: Int64 = 0
      for source in model.sources {
        for file in source.files {
          guard let url = source.url(for: file) else { throw CatalogInstallError.missingFile(path: file.path) }
          received += try await fetch(
            file,
            from: url,
            to: staging.appending(path: source.installPath(for: file)),
            alreadyReceived: received,
            modelLimit: model.totalBytes,
            configuration: configuration,
            progress: progress)
        }
      }
      for path in model.installPaths {
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: staging.appending(path: path).path)
      }
      try promote(staging, to: installFolder(for: model))
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
    try writeManifest(for: model)
    return installFolder(for: model)
  }

  /// The call a recognizer makes before every load: re-hashes every pinned file and returns
  /// the folder only when all of them still match the bundled catalog.
  ///
  /// Throws rather than repairing, so the session falls back to Apple Speech and Settings
  /// can offer Re-download. This guards integrity, not a local attacker: anyone who can edit
  /// these files can also edit the unsandboxed app.
  func verifiedFolder(for model: CatalogModel) throws -> URL {
    try refuseIfBlocked(model)
    let folder = installFolder(for: model)
    guard FileManager.default.fileExists(atPath: folder.path) else { throw CatalogInstallError.notInstalled }
    let resolvedFolder = folder.resolvingSymlinksInPath()
    for (path, file) in zip(model.installPaths, model.files) {
      let url = folder.appending(path: path)
      // A symlink anywhere on the path could point the runtime at bytes nobody hashed here.
      guard url.resolvingSymlinksInPath().path == resolvedFolder.appending(path: path).path,
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        values.isRegularFile == true, let size = values.fileSize
      else { throw CatalogInstallError.missingFile(path: path) }
      guard Int64(size) == file.size else {
        throw CatalogInstallError.sizeMismatch(path: path, expected: file.size, actual: Int64(size))
      }
      guard try Self.sha256(of: url) == file.sha256 else { throw CatalogInstallError.hashMismatch(path: path) }
    }
    return folder
  }

  /// Removes everything the installer wrote for `model` (every installed pin, any staging a
  /// crash left behind, the manifest) and what Core ML compiled from it.
  ///
  /// The Neural Engine daemon may keep its own copy outside this app's reach; whether it
  /// does is unknown. The compile a later install pays shows this one is gone.
  func delete(_ model: CatalogModel) throws {
    let fileManager = FileManager.default
    for folder in [modelFolder(for: model), compiledModelCache].compactMap(\.self)
    where fileManager.fileExists(atPath: folder.path) {
      try fileManager.removeItem(at: folder)
    }
  }

  /// The first 16 hex digits of a SHA-256 over every install path, size and digest.
  static func pin(for model: CatalogModel) -> String {
    var hasher = SHA256()
    for (path, file) in zip(model.installPaths, model.files) {
      hasher.update(data: Data("\(path)\t\(file.size)\t\(file.sha256)\n".utf8))
    }
    return String(hex(hasher.finalize()).prefix(16))
  }

  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    // Read in chunks rather than mapping: a file truncated under a mapping crashes the app.
    // Each chunk is released before the next is read; without the pool every chunk of a
    // 648 MB model stayed alive until the caller returned, lifting the process by 1.2 GB.
    while try autoreleasepool(invoking: {
      guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
      hasher.update(data: chunk)
      return true
    }) {}
    return hex(hasher.finalize())
  }

  private func fetch(
    _ file: CatalogModel.File,
    from url: URL,
    to destination: URL,
    alreadyReceived: Int64,
    modelLimit: Int64,
    configuration: URLSessionConfiguration,
    progress: @Sendable (Int64) -> Void
  ) async throws -> Int64 {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard fileManager.createFile(atPath: destination.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
    }
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }

    var hasher = SHA256()
    var written: Int64 = 0
    let events = CatalogFetch.events(
      for: url, configuration: configuration, allowRedirect: CatalogLint.isRedirectAllowed)
    for try await event in events {
      switch event {
      case let .response(response):
        guard response.statusCode == 200 else {
          throw CatalogInstallError.httpStatus(path: file.path, status: response.statusCode)
        }
        // Refuse a declared oversize body before reading any of it.
        if response.expectedContentLength > file.size {
          throw CatalogInstallError.fileTooLarge(path: file.path, limit: file.size)
        }
      case let .data(chunk):
        try Task.checkCancellation()
        written += Int64(chunk.count)
        guard written <= file.size else { throw CatalogInstallError.fileTooLarge(path: file.path, limit: file.size) }
        guard alreadyReceived + written <= modelLimit else {
          throw CatalogInstallError.modelTooLarge(limit: modelLimit)
        }
        hasher.update(data: chunk)
        try handle.write(contentsOf: chunk)
        progress(alreadyReceived + written)
      }
    }
    // A cancelled task ends the stream quietly instead of throwing, so ask again here or a
    // cancel would be reported as a short file.
    try Task.checkCancellation()
    guard written == file.size else {
      throw CatalogInstallError.sizeMismatch(path: file.path, expected: file.size, actual: written)
    }
    guard Self.hex(hasher.finalize()) == file.sha256 else { throw CatalogInstallError.hashMismatch(path: file.path) }
    return written
  }

  /// One rename, so a load never sees a half-written model. A previous copy of the same pin
  /// (a Re-download after a failed check) is set aside first, because a rename cannot
  /// replace a folder that has contents.
  private func promote(_ staging: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: destination.path) else {
      try fileManager.moveItem(at: staging, to: destination)
      return
    }
    let replaced = destination.deletingLastPathComponent()
      .appending(path: destination.lastPathComponent + ".replaced", directoryHint: .isDirectory)
    try? fileManager.removeItem(at: replaced)
    try fileManager.moveItem(at: destination, to: replaced)
    try fileManager.moveItem(at: staging, to: destination)
    try? fileManager.removeItem(at: replaced)
  }

  private func writeManifest(for model: CatalogModel) throws {
    let manifest = InstalledManifest(
      id: model.id,
      pin: Self.pin(for: model),
      revisions: model.sources.map { "\($0.repository)@\($0.revision)" },
      catalogVersion: catalogVersion)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(
      to: modelFolder(for: model).appending(path: Self.manifestName), options: .atomic)
  }

  private func refuseIfBlocked(_ model: CatalogModel) throws {
    if model.revoked?.severity == .block { throw CatalogInstallError.revoked(model.id) }
  }

  private func checkSpace(for model: CatalogModel, at folder: URL) throws {
    let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
    let needed = Int64((Double(model.totalBytes) * Self.spaceMargin).rounded(.up))
    if available < needed { throw CatalogInstallError.insufficientSpace(needed: needed, available: available) }
  }

  private static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// What `installed.json` records, so a later catalog can tell which revision is on disk.
struct InstalledManifest: Codable, Equatable, Sendable {
  var id: String
  var pin: String
  var revisions: [String]
  var catalogVersion: Int
}
