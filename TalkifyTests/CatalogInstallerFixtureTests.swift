import CoreML
import Foundation
import Testing

@testable import Talkify

/// Installs the real Whisper turbo entry, served from local copies of its 24 files, and
/// reports what the check before every load costs at full size. Skipped unless
/// `TALKIFY_WHISPERKIT_FIXTURES` names the folder that holds
/// `openai_whisper-large-v3-v20240930_turbo_632MB/`.
@Suite(
  .enabled(if: ProcessInfo.processInfo.environment["TALKIFY_WHISPERKIT_FIXTURES"] != nil),
  .serialized
)
struct CatalogInstallerFixtureTests {
  @Test func theWhisperEntryInstallsFromLocalCopiesAndReHashesBeforeLoad() async throws {
    let fixtures = URL(
      fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TALKIFY_WHISPERKIT_FIXTURES"]),
      isDirectory: true)
    let model = try #require(try Catalog.bundled().models.first { $0.id == "whisper-large-v3-turbo-coreml" })
    for source in model.sources {
      for file in source.files {
        let local = fixtures.appending(path: source.installPath(for: file))
        FixtureURLProtocol.serve(
          .body(try Data(contentsOf: local, options: .mappedIfSafe)), at: try #require(source.url(for: file)))
      }
    }
    let root = FileManager.default.temporaryDirectory
      .appending(path: "CatalogInstallerFixtureTests-" + UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    // The real cache location, so this run shows where Core ML writes inside the app.
    let cache = try #require(CatalogInstaller.defaultCompiledModelCache)
    let installer = CatalogInstaller(root: root, compiledModelCache: cache, catalogVersion: 1) {
      FixtureURLProtocol.configuration()
    }

    let clock = ContinuousClock()
    let installStart = clock.now
    let folder = try await installer.install(model)
    let installTime = clock.now - installStart

    var rehashTimes: [Duration] = []
    for _ in 0..<3 {
      let start = clock.now
      #expect(try installer.verifiedFolder(for: model) == folder)
      rehashTimes.append(clock.now - start)
    }
    // An attachment, because a hosted test's stdout never reaches xcodebuild's log.
    Attachment.record(
      "install=\(installTime) rehash=\(rehashTimes) bytes=\(model.totalBytes)", named: "catalog-timings.txt")

    // The smallest of the four models compiles in under a second and is enough to show
    // where Core ML puts its cache for this app.
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    _ = try MLModel(
      contentsOf: folder.appending(path: "openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc"),
      configuration: configuration)
    #expect(FileManager.default.fileExists(atPath: cache.path))

    try installer.delete(model)
    #expect(!FileManager.default.fileExists(atPath: installer.modelFolder(for: model).path))
    #expect(!FileManager.default.fileExists(atPath: cache.path))
  }
}
