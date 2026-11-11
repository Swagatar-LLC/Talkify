import CryptoKit
import Foundation
import Testing

@testable import Talkify

struct CatalogInstallerTests {
  @Test func aGoodInstallPromotesEveryFileAndLeavesNoStaging() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()

    let folder = try await fixture.installer.install(fixture.model)

    #expect(folder == fixture.installer.installFolder(for: fixture.model))
    #expect(try Data(contentsOf: folder.appending(path: "model/" + InstallerFixture.weightsPath)) == fixture.weights)
    #expect(try Data(contentsOf: folder.appending(path: "model/config.json")) == fixture.config)
    #expect(!fixture.exists(fixture.installer.stagingFolder(for: fixture.model)))
    #expect(fixture.permissions(of: "model/config.json") == 0o444)

    let manifestURL = fixture.installer.modelFolder(for: fixture.model).appending(path: CatalogInstaller.manifestName)
    let manifest = try JSONDecoder().decode(InstalledManifest.self, from: Data(contentsOf: manifestURL))
    #expect(manifest.pin == CatalogInstaller.pin(for: fixture.model))
    #expect(manifest.revisions == ["\(fixture.repository)@\(InstallerFixture.revision)"])
    #expect(try fixture.installer.verifiedFolder(for: fixture.model) == folder)
  }

  @Test func aOneByteTamperIsRefusedAndNothingIsPromoted() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    var tampered = fixture.weights
    tampered[tampered.count / 2] ^= 0x01
    FixtureURLProtocol.serve(.body(tampered), at: fixture.cdnURL)

    await #expect(throws: CatalogInstallError.hashMismatch(path: InstallerFixture.weightsPath)) {
      try await fixture.installer.install(fixture.model)
    }
    #expect(fixture.leftNoModel)
  }

  @Test(arguments: [true, false])
  func anOversizeBodyStopsAtThePinnedSize(declaresLength: Bool) async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    FixtureURLProtocol.serve(.body(fixture.weights + Data([0]), declaresLength: declaresLength), at: fixture.cdnURL)

    await #expect(throws: CatalogInstallError.fileTooLarge(
      path: InstallerFixture.weightsPath, limit: Int64(fixture.weights.count))
    ) {
      try await fixture.installer.install(fixture.model)
    }
    #expect(fixture.leftNoModel)
  }

  @Test func aModelLargerThanItsTotalStopsEvenWhenEachFileFits() async throws {
    var fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    fixture.model.totalBytes -= 1

    await #expect(throws: CatalogInstallError.modelTooLarge(limit: fixture.model.totalBytes)) {
      try await fixture.installer.install(fixture.model)
    }
    #expect(fixture.leftNoModel)
  }

  @Test(arguments: [
    "https://evil.example/weight.bin",
    "http://huggingface.co/weight.bin",
    "http://us.aws.cdn.hf.co/weight.bin",
    "https://huggingface.co.evil.example/weight.bin",
    "https://cdn.hf.co.evil.example/weight.bin",
  ])
  func aRedirectOffTheAllowlistIsNeverFollowed(target: String) async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    // Unique per test, so a parallel argument cannot mark it as requested.
    let offList = try #require(URL(string: target + "?" + fixture.repository))
    FixtureURLProtocol.serve(.redirect(to: offList), at: fixture.url(0))
    FixtureURLProtocol.serve(.body(fixture.weights), at: offList)

    await #expect(throws: CatalogInstallError.redirectRefused(offList)) {
      try await fixture.installer.install(fixture.model)
    }
    #expect(!FixtureURLProtocol.wasStarted(offList))
    #expect(fixture.leftNoModel)
  }

  @Test func cancellingMidStreamStopsTheRequestAndRemovesStaging() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    FixtureURLProtocol.serve(.stall(first: fixture.weights.prefix(1000)), at: fixture.cdnURL)
    let installer = fixture.installer
    let model = fixture.model
    let (received, signal) = AsyncStream<Int64>.makeStream()

    let install = Task { try await installer.install(model) { signal.yield($0) } }
    for await bytes in received {
      #expect(bytes == 1000)
      break
    }
    #expect(fixture.exists(installer.stagingFolder(for: model)))
    install.cancel()

    await #expect(throws: CancellationError.self) { try await install.value }
    #expect(fixture.leftNoModel)
    for _ in 0..<100 where !FixtureURLProtocol.wasStopped(fixture.cdnURL) {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(FixtureURLProtocol.wasStopped(fixture.cdnURL))
  }

  @Test func aServerErrorFailsTheInstall() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    FixtureURLProtocol.serve(.status(404), at: fixture.url(1))

    await #expect(throws: CatalogInstallError.httpStatus(path: "config.json", status: 404)) {
      try await fixture.installer.install(fixture.model)
    }
    #expect(fixture.leftNoModel)
  }

  @Test func aByteChangedAfterInstallFailsTheCheckAtLoad() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    let folder = try await fixture.installer.install(fixture.model)

    let weights = folder.appending(path: "model/" + InstallerFixture.weightsPath)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: weights.path)
    var bytes = try Data(contentsOf: weights)
    bytes[0] ^= 0x01
    try bytes.write(to: weights)

    #expect(throws: CatalogInstallError.hashMismatch(path: "model/" + InstallerFixture.weightsPath)) {
      try fixture.installer.verifiedFolder(for: fixture.model)
    }
  }

  @Test func aTruncatedFileFailsTheCheckAtLoad() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    let folder = try await fixture.installer.install(fixture.model)

    let config = folder.appending(path: "model/config.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
    try Data(fixture.config.dropLast()).write(to: config)

    #expect(throws: CatalogInstallError.sizeMismatch(
      path: "model/config.json", expected: Int64(fixture.config.count), actual: Int64(fixture.config.count - 1))
    ) {
      try fixture.installer.verifiedFolder(for: fixture.model)
    }
  }

  /// The same bytes behind a symlink, so only the symlink checks can catch it: one for the
  /// file itself, one for a folder on its path.
  @Test(arguments: ["model/config.json", "model/Encoder.mlmodelc"])
  func aSymlinkInsideTheModelFailsTheCheckAtLoad(replacing path: String) async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    let folder = try await fixture.installer.install(fixture.model)

    let original = folder.appending(path: path)
    let elsewhere = fixture.root.appending(path: "elsewhere")
    try FileManager.default.copyItem(at: original, to: elsewhere)
    try FileManager.default.removeItem(at: original)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: elsewhere)

    let firstAffected = fixture.model.installPaths.first { $0 == path || $0.hasPrefix(path + "/") }
    #expect(throws: CatalogInstallError.missingFile(path: try #require(firstAffected))) {
      try fixture.installer.verifiedFolder(for: fixture.model)
    }
  }

  @Test func aModelNeverInstalledIsReportedAsSuch() throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    #expect(throws: CatalogInstallError.notInstalled) {
      try fixture.installer.verifiedFolder(for: fixture.model)
    }
  }

  @Test func reDownloadingReplacesADamagedInstall() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    let folder = try await fixture.installer.install(fixture.model)
    let config = folder.appending(path: "model/config.json")
    try FileManager.default.removeItem(at: config)

    #expect(try await fixture.installer.install(fixture.model) == folder)
    #expect(try fixture.installer.verifiedFolder(for: fixture.model) == folder)
  }

  @Test func deleteRemovesEverythingTheInstallerWrote() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    try await fixture.installer.install(fixture.model)
    // A staging folder a crash left behind goes too.
    try FileManager.default.createDirectory(
      at: fixture.installer.stagingFolder(for: fixture.model), withIntermediateDirectories: true)

    try FileManager.default.createDirectory(at: fixture.compiledModelCache, withIntermediateDirectories: true)

    try fixture.installer.delete(fixture.model)

    #expect(!fixture.exists(fixture.installer.modelFolder(for: fixture.model)))
    #expect(!fixture.exists(fixture.compiledModelCache))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["Caches"])
  }

  @Test func aBlockedModelIsNeitherFetchedNorLoaded() async throws {
    var fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    fixture.serveAll()
    fixture.model.revoked = CatalogModel.Revocation(date: "2026-11-10", reason: "test", severity: .block)

    await #expect(throws: CatalogInstallError.revoked(fixture.model.id)) {
      try await fixture.installer.install(fixture.model)
    }
    #expect(!FixtureURLProtocol.wasStarted(fixture.url(0)))
    #expect(throws: CatalogInstallError.revoked(fixture.model.id)) {
      try fixture.installer.verifiedFolder(for: fixture.model)
    }
  }

  @Test func thePinChangesWhenAnyPinnedByteDoes() throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    var changed = fixture.model
    changed.sources[0].files[1].sha256 = String(repeating: "0", count: 64)
    #expect(CatalogInstaller.pin(for: changed) != CatalogInstaller.pin(for: fixture.model))
    #expect(CatalogInstaller.pin(for: fixture.model).count == 16)
  }
}

/// A two-file model served from memory, its weights behind an allowed CDN redirect, the way
/// Hugging Face serves LFS files.
struct InstallerFixture {
  static let revision = String(repeating: "a", count: 40)
  static let weightsPath = "Encoder.mlmodelc/weights/weight.bin"

  let repository = "fixtures/" + UUID().uuidString.lowercased()
  let root = FileManager.default.temporaryDirectory
    .appending(path: "CatalogInstallerTests-" + UUID().uuidString, directoryHint: .isDirectory)
  /// Over 1 MiB, so it arrives in more than one chunk.
  let weights = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
  let config = Data(#"{"fixture": true}"#.utf8)
  var compiledModelCache: URL {
    root.appending(path: "Caches/com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory)
  }
  var model: CatalogModel

  init() throws {
    var model = try #require(try Catalog.bundled().models.first)
    model.id = "fixture-" + repository.dropFirst("fixtures/".count)
    model.mirrors = []
    model.revoked = nil
    model.sources = [
      CatalogModel.Source(
        host: "huggingface.co",
        repository: repository,
        revision: Self.revision,
        urlTemplate: "https://huggingface.co/{repository}/resolve/{revision}/{path}",
        installFolder: "model",
        files: [
          CatalogModel.File(
            path: Self.weightsPath, size: Int64(weights.count), sha256: Self.hex(weights)),
          CatalogModel.File(path: "config.json", size: Int64(config.count), sha256: Self.hex(config)),
        ])
    ]
    model.totalBytes = Int64(weights.count + config.count)
    self.model = model
  }

  var installer: CatalogInstaller {
    CatalogInstaller(root: root, compiledModelCache: compiledModelCache, catalogVersion: 1) {
      FixtureURLProtocol.configuration()
    }
  }

  var cdnURL: URL { URL(string: "https://us.aws.cdn.hf.co/\(repository)/weight.bin")! }

  func url(_ index: Int) -> URL { model.sources[0].url(for: model.files[index])! }

  func serveAll() {
    FixtureURLProtocol.serve(.redirect(to: cdnURL), at: url(0))
    FixtureURLProtocol.serve(.body(weights), at: cdnURL)
    FixtureURLProtocol.serve(.body(config), at: url(1))
  }

  var leftNoModel: Bool {
    !exists(installer.stagingFolder(for: model)) && !exists(installer.installFolder(for: model))
  }

  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  func permissions(of path: String) -> Int? {
    let url = installer.installFolder(for: model).appending(path: path)
    return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
  }

  func cleanUp() { try? FileManager.default.removeItem(at: root) }

  static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
