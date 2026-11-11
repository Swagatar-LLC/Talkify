import Foundation
import os
import Testing

@testable import Talkify

/// A client whose every step is scripted, and which records the order steps ran in.
private final class ScriptedClient: Sendable {
  struct Script: Sendable {
    var installed = false
    var downloadError: (any Error)?
    var verifyError: (any Error)?
    var prepareError: (any Error)?
    var deleteError: (any Error)?
    /// Holds Download open until the task is cancelled.
    var downloadHangs = false
  }

  let script: OSAllocatedUnfairLock<Script>
  let calls = OSAllocatedUnfairLock<[String]>(initialState: [])

  init(_ script: Script = Script()) {
    self.script = OSAllocatedUnfairLock(initialState: script)
  }

  var steps: [String] { calls.withLock { $0 } }

  var client: RecognizerStore.Client {
    RecognizerStore.Client(
      isInstalled: { [self] _ in script.withLock(\.installed) },
      download: { [self] model, progress in
        calls.withLock { $0.append("download") }
        let script = script.withLock { $0 }
        if script.downloadHangs {
          while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
          throw CancellationError()
        }
        progress(model.totalBytes / 2)
        progress(model.totalBytes)
        if let error = script.downloadError { throw error }
        self.script.withLock { $0.installed = true }
      },
      verify: { [self] _ in
        calls.withLock { $0.append("verify") }
        if let error = script.withLock(\.verifyError) { throw error }
        return URL(filePath: "/verified")
      },
      prepare: { [self] _, folder in
        calls.withLock { $0.append("prepare \(folder.path)") }
        if let error = script.withLock(\.prepareError) { throw error }
      },
      delete: { [self] _ in
        calls.withLock { $0.append("delete") }
        if let error = script.withLock(\.deleteError) { throw error }
        script.withLock { $0.installed = false }
      }
    )
  }
}

private struct LoadFailure: LocalizedError {
  var errorDescription: String? { "Core ML ran out of memory." }
}

@MainActor
struct RecognizerStoreTests {
  private static let macOS27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
  private static let macOS2662 = OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 2)

  private static func whisper(
    status: CatalogModel.Status = .available,
    revoked: CatalogModel.Revocation? = nil
  ) throws -> CatalogModel {
    var model = try #require(try Catalog.bundled().models.first { $0.id == "whisper-large-v3-turbo-coreml" })
    model.status = status
    model.revoked = revoked
    return model
  }

  private static func freshSettings() -> (AppSettings, UserDefaults) {
    let name = "RecognizerStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return (AppSettings(defaults: defaults), defaults)
  }

  private static func store(
    _ model: CatalogModel,
    client: ScriptedClient,
    settings: AppSettings = freshSettings().0,
    systemVersion: OperatingSystemVersion = macOS27
  ) -> RecognizerStore {
    RecognizerStore(
      catalog: Catalog(schemaVersion: 1, catalogVersion: 1, models: [model]),
      settings: settings,
      client: client.client,
      systemVersion: systemVersion
    )
  }

  private static func settle(_ store: RecognizerStore, _ model: CatalogModel) async {
    for _ in 0..<500 where store.isInstalling(model) {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }

  // Listing and the system requirement.

  @Test func appleSpeechIsTheDefaultAndNothingIsChosen() throws {
    let store = Self.store(try Self.whisper(), client: ScriptedClient())
    #expect(store.selectedModelID == nil)
    #expect(store.listedModels.map(\.id) == ["whisper-large-v3-turbo-coreml"])
    #expect(store.olderSystemNote == nil)
  }

  @Test(arguments: [
    (OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 2), false),
    (OperatingSystemVersion(majorVersion: 26, minorVersion: 7, patchVersion: 0), true),
    (OperatingSystemVersion(majorVersion: 26, minorVersion: 10, patchVersion: 0), true),
    (OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0), true),
    (OperatingSystemVersion(majorVersion: 25, minorVersion: 9, patchVersion: 9), false),
  ])
  func anOlderSystemListsAppleSpeechOnly(version: OperatingSystemVersion, lists: Bool) throws {
    let store = Self.store(try Self.whisper(), client: ScriptedClient(), systemVersion: version)
    #expect(store.listedModels.isEmpty == !lists)
    #expect((store.olderSystemNote == nil) == lists)
  }

  @Test func theOlderSystemNoteNamesBothVersions() throws {
    let store = Self.store(try Self.whisper(), client: ScriptedClient(), systemVersion: Self.macOS2662)
    #expect(store.olderSystemNote == "Downloadable recognizers need macOS 26.7 or later. "
      + "This Mac runs macOS 26.6.2, so Apple Speech is the only choice.")
  }

  @Test func anOlderSystemNeverResolvesTheChosenModelEvenIfOneWasStored() async throws {
    let model = try Self.whisper()
    let client = ScriptedClient(.init(installed: true))
    let (settings, _) = Self.freshSettings()
    settings.recognizerModelID = model.id
    let store = Self.store(model, client: client, settings: settings, systemVersion: Self.macOS2662)

    let loaded = await store.prepareChosenModel { _, _ in "whisper" }
    #expect(loaded == nil)
    #expect(store.notice == nil)
    #expect(client.steps.isEmpty)
  }

  @Test func anUnreadableRequirementIsNeverSatisfied() {
    #expect(!SystemRequirement.isSatisfied(minimum: "26.x", by: Self.macOS27))
    #expect(!SystemRequirement.isSatisfied(minimum: "", by: Self.macOS27))
    #expect(SystemRequirement.isSatisfied(minimum: "27", by: Self.macOS27))
    #expect(!SystemRequirement.isSatisfied(minimum: "26.6.3", by: Self.macOS2662))
  }

  @Test func aProposedEntryIsListedButNotOfferedForDownload() async throws {
    let model = try Self.whisper(status: .proposed)
    let client = ScriptedClient()
    let store = Self.store(model, client: client)
    #expect(store.listedModels.map(\.id) == [model.id])
    #expect(!store.canDownload(model))
    store.install(model)
    #expect(store.installs.isEmpty)
    #expect(client.steps.isEmpty)
  }

  @Test func aBlockedEntryIsHiddenUnlessItIsOnDisk() throws {
    let revocation = CatalogModel.Revocation(date: "2026-12-01", reason: "Bad weights.", severity: .block)
    let model = try Self.whisper(status: .revoked, revoked: revocation)
    #expect(Self.store(model, client: ScriptedClient()).listedModels.isEmpty)

    let onDisk = Self.store(model, client: ScriptedClient(.init(installed: true)))
    #expect(onDisk.listedModels.map(\.id) == [model.id])
    #expect(!onDisk.canUse(model))
  }

  // Install.

  @Test func installRunsDownloadVerifyPrepareInOrderAndEndsReady() async throws {
    let model = try Self.whisper()
    let client = ScriptedClient()
    let store = Self.store(model, client: client)

    store.install(model)
    #expect(store.installs[model.id]?.stage == .download)
    await Self.settle(store, model)

    #expect(client.steps == ["download", "verify", "prepare /verified"])
    #expect(store.installs[model.id]?.outcome == .ready)
    #expect(store.installs[model.id]?.receivedBytes == model.totalBytes)
    #expect(store.isInstalled(model))
    #expect(store.canUse(model))
    // Install never chooses the model on its own.
    #expect(store.selectedModelID == nil)
  }

  @Test func aFailedDownloadStopsBeforeVerifyAndLeavesNothingInstalled() async throws {
    let model = try Self.whisper()
    let client = ScriptedClient(.init(downloadError: CatalogInstallError.hashMismatch(path: "weights.bin")))
    let store = Self.store(model, client: client)

    store.install(model)
    await Self.settle(store, model)

    #expect(client.steps == ["download"])
    guard case .failed(.download, let reason) = store.installs[model.id]?.outcome else {
      Issue.record("expected a download failure, got \(String(describing: store.installs[model.id]))")
      return
    }
    #expect(reason.contains("fingerprint"))
    #expect(!store.isInstalled(model))
    #expect(store.canDownload(model))
  }

  @Test func aFailedPrepareKeepsTheFilesAndSaysWhichStage() async throws {
    let model = try Self.whisper()
    let client = ScriptedClient(.init(prepareError: LoadFailure()))
    let store = Self.store(model, client: client)

    store.install(model)
    await Self.settle(store, model)

    #expect(store.installs[model.id]?.outcome == .failed(.prepare, "Core ML ran out of memory."))
    #expect(store.isInstalled(model))
  }

  @Test func cancellingADownloadClearsItsProgressAndSkipsTheRest() async throws {
    let model = try Self.whisper()
    let client = ScriptedClient(.init(downloadHangs: true))
    let store = Self.store(model, client: client)

    store.install(model)
    try await Task.sleep(for: .milliseconds(20))
    #expect(store.isInstalling(model))
    store.cancelInstall(model)
    await Self.settle(store, model)

    #expect(store.installs[model.id] == nil)
    #expect(client.steps == ["download"])
    #expect(!store.isInstalled(model))
  }

  // Use, Delete and the stored choice.

  @Test func useAndDeletePersistTheChoiceUnderItsKey() async throws {
    let model = try Self.whisper()
    let client = ScriptedClient(.init(installed: true))
    let (settings, defaults) = Self.freshSettings()
    let store = Self.store(model, client: client, settings: settings)

    store.use(model)
    #expect(defaults.string(forKey: "dictationRecognizerModelID") == model.id)
    #expect(AppSettings(defaults: defaults).recognizerModelID == model.id)

    store.delete(model)
    #expect(client.steps == ["delete"])
    #expect(store.selectedModelID == nil)
    #expect(AppSettings(defaults: defaults).recognizerModelID == "")
    #expect(!store.isInstalled(model))
  }

  @Test func aModelThatIsNotInstalledCannotBeChosen() throws {
    let model = try Self.whisper()
    let store = Self.store(model, client: ScriptedClient())
    store.use(model)
    #expect(store.selectedModelID == nil)
  }

  @Test func aFailedDeleteSaysSoAndStillHandsBackToAppleSpeech() throws {
    let model = try Self.whisper()
    let client = ScriptedClient(.init(installed: true, deleteError: CocoaError(.fileWriteNoPermission)))
    let store = Self.store(model, client: client)
    store.use(model)

    store.delete(model)
    #expect(store.selectedModelID == nil)
    #expect(store.deleteFailure?.hasPrefix("Whisper large-v3-turbo could not be deleted") == true)
    #expect(store.isInstalled(model))
  }

  @Test func downloadAgainDeletesThenReinstallsAndKeepsTheChoice() async throws {
    let model = try Self.whisper()
    let client = ScriptedClient(.init(installed: true))
    let store = Self.store(model, client: client)
    store.use(model)
    store.report(.hashMismatch, for: model)

    store.redownload(model)
    await Self.settle(store, model)

    #expect(client.steps == ["delete", "download", "verify", "prepare /verified"])
    #expect(store.selectedModelID == model.id)
    #expect(store.notice == nil)
  }

  // Every failure preparing the chosen model, each driven by an injected failure. The
  // store only says what it found; the session that falls back posts the notice
  // (DictationRecognizersTests).

  private static func fallback<Loaded>(_ preparation: CatalogPreparation<Loaded>?) -> RecognizerFallback? {
    guard case .failed(_, let fallback)? = preparation else { return nil }
    return fallback
  }

  @Test(arguments: [
    (CatalogInstallError.missingFile(path: "a/weight.bin") as any Error, RecognizerFallback.filesMissing),
    (CatalogInstallError.notInstalled, .filesMissing),
    (CatalogInstallError.sizeMismatch(path: "a/weight.bin", expected: 10, actual: 9), .filesMissing),
    (CatalogInstallError.hashMismatch(path: "a/weight.bin"), .hashMismatch),
    (CatalogInstallError.revoked("Bad weights."), .revoked("Bad weights.")),
  ])
  func aVerifyFailureIsReturnedWithoutLoadingOrDownloading(error: any Error, expected: RecognizerFallback) async throws {
    let model = try Self.whisper()
    let client = ScriptedClient(.init(installed: true, verifyError: error))
    let store = Self.store(model, client: client)
    store.use(model)

    var loads = 0
    let prepared = await store.prepareChosenModel { _, _ in loads += 1; return "whisper" }

    #expect(Self.fallback(prepared) == expected)
    #expect(prepared?.model.id == model.id)
    #expect(loads == 0)
    #expect(store.notice == nil)
    // The choice stands: nothing re-downloads or switches on its own.
    #expect(store.selectedModelID == model.id)
    #expect(client.steps == ["verify"])
  }

  @Test func aRevokedModelFailsWithoutTouchingItsFiles() async throws {
    let installed = try Self.whisper()
    let client = ScriptedClient(.init(installed: true))
    let (settings, _) = Self.freshSettings()
    settings.recognizerModelID = installed.id
    let revoked = try Self.whisper(revoked: .init(date: "2026-12-01", reason: "Bad weights.", severity: .block))
    let store = Self.store(revoked, client: client, settings: settings)

    let prepared = await store.prepareChosenModel { _, _ in "whisper" }

    #expect(Self.fallback(prepared) == .revoked("Bad weights."))
    #expect(client.steps.isEmpty)
  }

  @Test func anAdvisoryRevocationStillLoads() async throws {
    let model = try Self.whisper(revoked: .init(date: "2026-12-01", reason: "Superseded.", severity: .advisory))
    let client = ScriptedClient(.init(installed: true))
    let store = Self.store(model, client: client)
    store.use(model)

    let prepared = await store.prepareChosenModel { _, _ in "whisper" }
    guard case .ready(_, let loaded)? = prepared else {
      Issue.record("expected a loaded model, got \(String(describing: prepared))")
      return
    }
    #expect(loaded == "whisper")
  }

  @Test func aLanguageIsJudgedPerSessionNotWhenLoading() async throws {
    let model = try Self.whisper()
    let store = Self.store(model, client: ScriptedClient(.init(installed: true)))
    store.use(model)

    let prepared = try #require(await store.prepareChosenModel { _, _ in "whisper" })
    #expect(prepared.fallback(forLanguage: "en") == nil)
    #expect(prepared.fallback(forLanguage: "xx") == .unsupportedLanguage("xx"))
    #expect(RecognizerStore.catalogLanguage(of: Locale(identifier: "en_GB")) == "en")
  }

  @Test func aRuntimeRefusingTheLanguageIsTheSameFallback() async throws {
    let model = try Self.whisper()
    let store = Self.store(model, client: ScriptedClient(.init(installed: true)))
    store.use(model)

    let prepared: CatalogPreparation<String>? = await store.prepareChosenModel { _, _ in
      throw WhisperRecognizer.Failure.unsupportedLanguage("en_US")
    }
    #expect(Self.fallback(prepared) == .unsupportedLanguage("en_US"))
  }

  @Test func aLoadErrorFailsWithTheRuntimesReason() async throws {
    let model = try Self.whisper()
    let client = ScriptedClient(.init(installed: true))
    let store = Self.store(model, client: client)
    store.use(model)

    let prepared: CatalogPreparation<String>? = await store.prepareChosenModel { _, folder in
      #expect(folder.path == "/verified")
      throw WhisperRecognizer.Failure.loadFailed("Core ML ran out of memory.")
    }

    #expect(Self.fallback(prepared) == .loadFailed("Core ML ran out of memory."))
    #expect(client.steps == ["verify"])
  }

  @Test func aHealthyChosenModelLoadsFromTheVerifiedFolder() async throws {
    let model = try Self.whisper()
    let client = ScriptedClient(.init(installed: true))
    let store = Self.store(model, client: client)
    store.use(model)

    let prepared = await store.prepareChosenModel { model, folder in
      "\(model.id) \(folder.path)"
    }
    guard case .ready(_, let loaded)? = prepared else {
      Issue.record("expected a loaded model, got \(String(describing: prepared))")
      return
    }
    #expect(loaded == "whisper-large-v3-turbo-coreml /verified")
    #expect(store.notice == nil)
  }

  @Test func appleSpeechChosenNeverVerifiesOrLoads() async throws {
    let client = ScriptedClient(.init(installed: true))
    let store = Self.store(try Self.whisper(), client: client)
    let prepared = await store.prepareChosenModel { _, _ in "whisper" }
    #expect(prepared == nil)
    #expect(store.notice == nil)
    #expect(client.steps.isEmpty)
  }

  @Test func choosingTheModelAgainClearsItsNotice() throws {
    let model = try Self.whisper()
    let store = Self.store(model, client: ScriptedClient(.init(installed: true)))
    store.report(.loadFailed("x"), for: model)
    store.use(model)
    #expect(store.notice == nil)
  }

  @Test func everyNoticeSaysAppleSpeechWasUsed() {
    let fallbacks: [RecognizerFallback] = [
      .filesMissing, .hashMismatch, .revoked("Bad."), .unsupportedLanguage("de"), .loadFailed("Boom."),
    ]
    for fallback in fallbacks {
      let notice = RecognizerNotice(modelID: "m", modelName: "Model", fallback: fallback)
      #expect(notice.message.contains("Apple Speech was used"), "\(fallback)")
    }
  }
}
