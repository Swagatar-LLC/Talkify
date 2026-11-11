import AVFAudio
import Foundation
import os
import Testing

@testable import Talkify

/// A catalog client whose Verify fails as scripted, and which records every call, so a
/// test can show that no fallback ever downloads.
private final class CatalogClientSpy: Sendable {
  let verifyError = OSAllocatedUnfairLock<(any Error)?>(initialState: nil)
  private let log = OSAllocatedUnfairLock<[String]>(initialState: [])

  var calls: [String] { log.withLock { $0 } }

  var client: RecognizerStore.Client {
    RecognizerStore.Client(
      isInstalled: { _ in true },
      download: { [log] _, _ in log.withLock { $0.append("download") } },
      verify: { [log, verifyError] _ in
        log.withLock { $0.append("verify") }
        if let error = verifyError.withLock({ $0 }) { throw error }
        return URL(filePath: "/verified")
      },
      prepare: { [log] _, _ in log.withLock { $0.append("prepare") } },
      delete: { [log] _ in log.withLock { $0.append("delete") } }
    )
  }
}

/// Holds a load open until the test lets it finish.
private final class LoadGate: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func wait() async {
    for await _ in stream { return }
  }

  func open() {
    continuation.yield()
  }
}

/// Which Recognizer each Direct Dictation session runs on, and that every Catalog Model
/// failure runs it on Apple Speech with its Settings notice and no download.
@MainActor
struct DictationRecognizersTests {
  private struct Rig {
    let recognizers: DictationRecognizers
    let store: RecognizerStore
    let settings: AppSettings
    let spy: CatalogClientSpy
    let appleSpeech: FakeRecognizer
    let catalogModel: FakeRecognizer
    let model: CatalogModel
    let loads: LoadLog
  }

  @MainActor
  private final class LoadLog {
    var hints: [[String]] = []
    var error: (any Error)?
    var gate: LoadGate?
  }

  private static let macOS27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1)

  private func makeRig(revoked: CatalogModel.Revocation? = nil) throws -> Rig {
    var model = try #require(try Catalog.bundled().models.first { $0.id == "whisper-large-v3-turbo-coreml" })
    model.status = .available
    model.revoked = revoked
    let name = "DictationRecognizersTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    let settings = AppSettings(defaults: defaults)
    let spy = CatalogClientSpy()
    let store = RecognizerStore(
      catalog: Catalog(schemaVersion: 1, catalogVersion: 1, models: [model]),
      settings: settings,
      client: spy.client,
      systemVersion: Self.macOS27
    )
    let appleSpeech = FakeRecognizer()
    let catalogModel = FakeRecognizer()
    let loads = LoadLog()
    let recognizers = DictationRecognizers(
      appleSpeech: appleSpeech,
      store: store,
      load: { _, folder, hints in
        #expect(folder.path == "/verified")
        loads.hints.append(hints)
        await loads.gate?.wait()
        if let error = loads.error { throw error }
        await catalogModel.setHints(hints)
        return catalogModel
      },
      startCapture: { format, feed, _, _ in
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        _ = feed(buffer)
        return {}
      }
    )
    return Rig(
      recognizers: recognizers, store: store, settings: settings, spy: spy,
      appleSpeech: appleSpeech, catalogModel: catalogModel, model: model, loads: loads
    )
  }

  /// One whole session in `locale`; returns which Recognizer heard it.
  private func runSession(_ rig: Rig, in locale: String = "en_US") async throws -> String {
    let appleStarts = rig.appleSpeech.entries.filter { $0.hasPrefix("start:") }.count
    try await rig.recognizers.start(
      locale: Locale(identifier: locale),
      updateHandler: { _ in },
      failureHandler: { _ in },
      levelHandler: { _ in }
    )
    _ = try await rig.recognizers.finish()
    return rig.appleSpeech.entries.filter { $0.hasPrefix("start:") }.count > appleStarts
      ? "Apple Speech" : "Catalog Model"
  }

  @Test func appleSpeechChosenRunsOnAppleSpeechAndNeverTouchesTheCatalog() async throws {
    let rig = try makeRig()
    await rig.recognizers.prepare()

    #expect(try await runSession(rig) == "Apple Speech")
    #expect(rig.spy.calls.isEmpty)
    #expect(rig.loads.hints.isEmpty)
    #expect(rig.store.notice == nil)
  }

  @Test func theChosenModelRunsTheSessionWithTheVocabulary() async throws {
    let rig = try makeRig()
    await rig.recognizers.setHints(["Talkify", "Wren"])
    rig.store.use(rig.model)
    await rig.recognizers.prepare()

    #expect(try await runSession(rig) == "Catalog Model")
    #expect(rig.loads.hints == [["Talkify", "Wren"]])
    #expect(rig.catalogModel.entries.prefix(2) == ["hints:Talkify,Wren", "start:en_US"])
    #expect(rig.catalogModel.entries.last == "finish")
    #expect(rig.store.notice == nil)

    // Warm stays warm: preparing again neither re-verifies nor reloads.
    await rig.recognizers.prepare()
    #expect(rig.spy.calls == ["verify"])
    #expect(rig.loads.hints.count == 1)
    #expect(try await runSession(rig) == "Catalog Model")
  }

  // Every failure the card names, each run as a session.

  @Test(arguments: [
    (CatalogInstallError.missingFile(path: "a/weight.bin") as any Error, RecognizerFallback.filesMissing),
    (CatalogInstallError.notInstalled, .filesMissing),
    (CatalogInstallError.sizeMismatch(path: "a/weight.bin", expected: 10, actual: 9), .filesMissing),
    (CatalogInstallError.hashMismatch(path: "a/weight.bin"), .hashMismatch),
    (CatalogInstallError.revoked("Bad weights."), .revoked("Bad weights.")),
  ])
  func aFileFailureRunsTheSessionOnAppleSpeechWithItsNotice(
    error: any Error, expected: RecognizerFallback
  ) async throws {
    let rig = try makeRig()
    rig.store.use(rig.model)
    rig.spy.verifyError.withLock { $0 = error }
    await rig.recognizers.prepare()

    #expect(rig.store.notice == nil, "posted before any session fell back")
    #expect(try await runSession(rig) == "Apple Speech")
    #expect(rig.store.notice?.fallback == expected)
    #expect(rig.store.notice?.modelID == rig.model.id)
    #expect(rig.store.notice?.message.contains("Apple Speech was used") == true)
    #expect(rig.loads.hints.isEmpty)
    #expect(!rig.spy.calls.contains("download"))
    #expect(rig.store.selectedModelID == rig.model.id)
  }

  @Test func aModelWithdrawnAtBlockSeverityRunsOnAppleSpeechWithoutTouchingItsFiles() async throws {
    let rig = try makeRig(revoked: .init(date: "2026-12-01", reason: "Bad weights.", severity: .block))
    rig.settings.recognizerModelID = rig.model.id
    await rig.recognizers.prepare()

    #expect(try await runSession(rig) == "Apple Speech")
    #expect(rig.store.notice?.fallback == .revoked("Bad weights."))
    #expect(rig.spy.calls.isEmpty)
  }

  @Test func anUnsupportedLanguageRunsThatSessionOnAppleSpeechOnly() async throws {
    let rig = try makeRig()
    rig.store.use(rig.model)
    await rig.recognizers.prepare()

    #expect(try await runSession(rig, in: "de_DE") == "Apple Speech")
    #expect(rig.store.notice?.fallback == .unsupportedLanguage("de"))
    #expect(rig.store.notice?.message.hasSuffix("so Apple Speech was used for that session.") == true)

    // The next English session is the model's again; nothing was unloaded.
    #expect(try await runSession(rig) == "Catalog Model")
    #expect(rig.loads.hints.count == 1)
    #expect(!rig.spy.calls.contains("download"))
  }

  @Test func aLoadErrorRunsTheSessionOnAppleSpeechWithTheRuntimesReason() async throws {
    let rig = try makeRig()
    rig.store.use(rig.model)
    rig.loads.error = WhisperRecognizer.Failure.loadFailed("Core ML ran out of memory.")
    await rig.recognizers.prepare()

    #expect(try await runSession(rig) == "Apple Speech")
    #expect(rig.store.notice?.fallback == .loadFailed("Core ML ran out of memory."))
    #expect(rig.store.notice?.message.hasPrefix(
      "Whisper large-v3-turbo failed to load, so Apple Speech was used.") == true)
    #expect(!rig.spy.calls.contains("download"))
  }

  @Test func everySessionAfterAFailureFallsBackAgainAndSaysSo() async throws {
    let rig = try makeRig()
    rig.store.use(rig.model)
    rig.spy.verifyError.withLock { $0 = CatalogInstallError.hashMismatch(path: "a") }
    await rig.recognizers.prepare()

    #expect(try await runSession(rig) == "Apple Speech")
    rig.store.dismissNotice()
    #expect(try await runSession(rig) == "Apple Speech")
    #expect(rig.store.notice?.fallback == .hashMismatch)
  }

  @Test func filesRestoredByTheUserCountAtTheNextPreparation() async throws {
    let rig = try makeRig()
    rig.store.use(rig.model)
    rig.spy.verifyError.withLock { $0 = CatalogInstallError.notInstalled }
    await rig.recognizers.prepare()
    #expect(try await runSession(rig) == "Apple Speech")

    rig.spy.verifyError.withLock { $0 = nil }
    await rig.recognizers.prepare()
    #expect(try await runSession(rig) == "Catalog Model")
    #expect(rig.spy.calls == ["verify", "verify"])
  }

  // The session settings snapshot (ADR-0004).

  @Test func aRecognizerChangedMidSessionAppliesToTheNextSession() async throws {
    let rig = try makeRig()
    rig.store.use(rig.model)
    await rig.recognizers.prepare()

    try await rig.recognizers.start(
      locale: Locale(identifier: "en_US"), updateHandler: { _ in }, failureHandler: { _ in }, levelHandler: { _ in })
    rig.store.use(nil)
    await rig.recognizers.prepare()
    #expect(rig.recognizers.preparation == nil)
    _ = try await rig.recognizers.finish()

    #expect(rig.catalogModel.entries.last == "finish")
    #expect(!rig.appleSpeech.entries.contains("finish"))
    #expect(try await runSession(rig) == "Apple Speech")
  }

  @Test func aNewChoiceAppliesOnceItsModelIsWarm() async throws {
    let rig = try makeRig()
    let gate = LoadGate()
    rig.loads.gate = gate
    rig.store.use(rig.model)
    let preparing = Task { await rig.recognizers.prepare() }
    while rig.loads.hints.isEmpty { await Task.yield() }

    // Mid-load: the keypress is not held for the load, and nothing failed.
    #expect(try await runSession(rig) == "Apple Speech")
    #expect(rig.store.notice == nil)

    gate.open()
    await preparing.value
    #expect(try await runSession(rig) == "Catalog Model")
  }

  @Test func vocabularyChangedDuringALoadReachesTheLoadedModel() async throws {
    let rig = try makeRig()
    let gate = LoadGate()
    rig.loads.gate = gate
    await rig.recognizers.setHints(["Talkify"])
    rig.store.use(rig.model)
    let preparing = Task { await rig.recognizers.prepare() }
    while rig.loads.hints.isEmpty { await Task.yield() }

    await rig.recognizers.setHints(["Talkify", "Wren"])
    gate.open()
    await preparing.value

    #expect(rig.catalogModel.entries.filter { $0.hasPrefix("hints:") } == ["hints:Talkify", "hints:Talkify,Wren"])
  }

  @Test func twoPreparationsOfOneChoiceLoadItOnce() async throws {
    let rig = try makeRig()
    let gate = LoadGate()
    rig.loads.gate = gate
    rig.store.use(rig.model)
    let first = Task { await rig.recognizers.prepare() }
    while rig.loads.hints.isEmpty { await Task.yield() }
    let second = Task { await rig.recognizers.prepare() }
    for _ in 0..<10 { await Task.yield() }

    gate.open()
    await first.value
    await second.value
    #expect(rig.loads.hints.count == 1)
    #expect(try await runSession(rig) == "Catalog Model")
  }

  @Test func aChoiceAbandonedMidLoadIsNotInstalled() async throws {
    let rig = try makeRig()
    let gate = LoadGate()
    rig.loads.gate = gate
    rig.store.use(rig.model)
    let preparing = Task { await rig.recognizers.prepare() }
    while rig.loads.hints.isEmpty { await Task.yield() }

    rig.store.use(nil)
    await rig.recognizers.prepare()
    gate.open()
    await preparing.value

    #expect(rig.recognizers.preparation == nil)
    #expect(try await runSession(rig) == "Apple Speech")
  }
}
