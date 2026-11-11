import Foundation
import Observation
import os

/// Which Recognizer Direct Dictation uses, and every Catalog Model's life on this Mac:
/// listed, downloaded, verified, prepared, chosen, deleted, or fallen back from.
///
/// Settings draws it and the session asks it which Recognizer to load. Apple Speech is
/// the default and the fallback; nothing here re-downloads or deletes on its own. The
/// file and network work goes through `Client`, so every failure can be injected.
@MainActor
@Observable
final class RecognizerStore {
  /// Everything that touches the disk, the network or a runtime.
  struct Client: Sendable {
    /// Whether the model's current pin is on disk. Cheap: it never hashes.
    var isInstalled: @Sendable (CatalogModel) -> Bool
    /// The one network call: fetch every file, reporting bytes received so far.
    var download: @Sendable (CatalogModel, @escaping @Sendable (Int64) -> Void) async throws -> Void
    /// Re-hashes every pinned file and returns the folder the runtime may load.
    var verify: @Sendable (CatalogModel) async throws -> URL
    /// Loads the model once and runs it once, so the Neural Engine compile is paid here.
    var prepare: @Sendable (CatalogModel, URL) async throws -> Void
    var delete: @Sendable (CatalogModel) throws -> Void
  }

  let catalog: Catalog
  let systemVersion: OperatingSystemVersion
  @ObservationIgnored private let settings: AppSettings
  @ObservationIgnored private let client: Client
  @ObservationIgnored private let now: @Sendable () -> Date

  private(set) var installedIDs: Set<String>
  /// The install in progress or just ended, per model id. Held here rather than in the
  /// sheet, so closing the sheet or leaving the pane never cancels a download.
  private(set) var installs: [String: InstallProgress]
  /// The last session's fallback, until dismissed or the user acts on it.
  private(set) var notice: RecognizerNotice?
  /// Why a Delete did not complete, until the next action.
  private(set) var deleteFailure: String?
  @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

  init(
    catalog: Catalog,
    settings: AppSettings,
    client: Client,
    systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
    now: @escaping @Sendable () -> Date = Date.init,
    installs: [String: InstallProgress] = [:],
    notice: RecognizerNotice? = nil
  ) {
    self.catalog = catalog
    self.settings = settings
    self.client = client
    self.systemVersion = systemVersion
    self.now = now
    self.installs = installs
    self.notice = notice
    installedIDs = Set(catalog.models.filter(client.isInstalled).map(\.id))
  }

  /// Re-reads what is on disk, for when Settings opens.
  func refresh() {
    installedIDs = Set(catalog.models.filter(client.isInstalled).map(\.id))
  }

  /// The entries the pane lists, in catalog order: those this system can run, minus
  /// withdrawn ones that were never downloaded. A withdrawn model that is on disk stays
  /// listed, so its reason and Delete are in reach.
  var listedModels: [CatalogModel] {
    guard !catalog.models.isEmpty else { return [] }
    return catalog.models.filter { model in
      guard runsOnThisSystem(model) else { return false }
      return model.status != .revoked || installedIDs.contains(model.id)
    }
  }

  func runsOnThisSystem(_ model: CatalogModel) -> Bool {
    SystemRequirement.isSatisfied(minimum: model.minHardware.minimumSystemVersion, by: systemVersion)
  }

  /// One line for a system older than every entry needs, or nil when any entry runs.
  var olderSystemNote: String? {
    let requirements = catalog.models.map(\.minHardware.minimumSystemVersion)
    guard !requirements.isEmpty, !catalog.models.contains(where: runsOnThisSystem) else { return nil }
    let lowest = requirements.min { (SystemRequirement.parse($0) ?? [.max])
      .lexicographicallyPrecedes(SystemRequirement.parse($1) ?? [.max]) } ?? requirements[0]
    return "Downloadable recognizers need macOS \(lowest) or later. This Mac runs macOS "
      + "\(SystemRequirement.describe(systemVersion)), so Apple Speech is the only choice."
  }

  /// The chosen Catalog Model, or nil for Apple Speech.
  var selectedModelID: String? {
    let id = settings.recognizerModelID
    return id.isEmpty ? nil : id
  }

  func isInstalled(_ model: CatalogModel) -> Bool { installedIDs.contains(model.id) }

  /// Only `available` entries offer Download; `proposed` ones are listed for review.
  func canDownload(_ model: CatalogModel) -> Bool {
    model.status == .available && model.revoked == nil && runsOnThisSystem(model)
      && !isInstalled(model) && !isInstalling(model)
  }

  func canUse(_ model: CatalogModel) -> Bool {
    isInstalled(model) && !isBlocked(model) && runsOnThisSystem(model) && !isInstalling(model)
  }

  func isInstalling(_ model: CatalogModel) -> Bool {
    guard let progress = installs[model.id] else { return false }
    return progress.outcome == nil
  }

  func isBlocked(_ model: CatalogModel) -> Bool {
    model.status == .revoked || model.revoked?.severity == .block
  }

  /// Chooses the Recognizer for the next session; nil is Apple Speech.
  func use(_ model: CatalogModel?) {
    deleteFailure = nil
    guard let model else {
      settings.recognizerModelID = ""
      return
    }
    guard canUse(model) else { return }
    settings.recognizerModelID = model.id
    if notice?.modelID == model.id { notice = nil }
  }

  /// Removes the model's files and compiled copy. A chosen model hands the choice back
  /// to Apple Speech first, so no session can reach for files that are going away.
  func delete(_ model: CatalogModel) {
    deleteFailure = nil
    if selectedModelID == model.id { settings.recognizerModelID = "" }
    do {
      try client.delete(model)
    } catch {
      deleteFailure = "\(model.displayName) could not be deleted: \(error.localizedDescription)"
    }
    installedIDs = Set(catalog.models.filter(client.isInstalled).map(\.id))
    installs[model.id] = nil
    if notice?.modelID == model.id { notice = nil }
  }

  /// Deletes whatever is left and downloads the model again; the cure Settings offers for
  /// missing or changed files.
  func redownload(_ model: CatalogModel) {
    let wasSelected = selectedModelID == model.id
    delete(model)
    guard deleteFailure == nil else { return }
    install(model, thenUse: wasSelected)
  }

  /// Download, verify, prepare. Each stage starts only when the one before succeeded; a
  /// failure stops there and says which stage it was.
  func install(_ model: CatalogModel, thenUse: Bool = false) {
    guard canDownload(model) else { return }
    deleteFailure = nil
    installs[model.id] = InstallProgress(totalBytes: model.totalBytes, startedAt: now())
    let throttle = ProgressThrottle(totalBytes: model.totalBytes)
    tasks[model.id] = Task { [client] in
      var stage = InstallProgress.Stage.download
      do {
        try await client.download(model) { received in
          guard throttle.shouldReport(received) else { return }
          Task { @MainActor [weak self] in self?.received(received, for: model.id) }
        }
        try Task.checkCancellation()
        stage = .verify
        advance(model.id, to: .verify)
        let folder = try await client.verify(model)
        installedIDs.insert(model.id)
        stage = .prepare
        advance(model.id, to: .prepare)
        try await client.prepare(model, folder)
        installs[model.id]?.outcome = .ready
        if thenUse { use(model) }
      } catch where stage == .download && Task.isCancelled {
        installs[model.id] = nil
      } catch {
        installs[model.id]?.outcome = .failed(stage, error.localizedDescription)
      }
      refresh()
      tasks[model.id] = nil
    }
  }

  /// Stops a download. Verify and prepare run to the end once started: both are short of
  /// a network and a half-compiled model is no better than a whole one.
  func cancelInstall(_ model: CatalogModel) {
    guard installs[model.id]?.stage == .download else { return }
    tasks[model.id]?.cancel()
  }

  /// Clears an ended install's ready or failed line.
  func dismissInstall(_ model: CatalogModel) {
    guard !isInstalling(model) else { return }
    installs[model.id] = nil
  }

  func dismissNotice() {
    notice = nil
  }

  /// Posts a fallback found outside this store, such as a session's runtime failing
  /// mid-load. It names the chosen model, as every notice does.
  func report(_ fallback: RecognizerFallback, for model: CatalogModel) {
    notice = RecognizerNotice(modelID: model.id, modelName: model.displayName, fallback: fallback)
  }

  /// The session's question: with the chosen model, can it start in `locale`? Returns
  /// what `load` built from the verified folder, or nil for Apple Speech, after posting
  /// the notice that says why. Apple Speech chosen, or a system too old to list any
  /// model, returns nil quietly: nothing the user chose was refused.
  func recognizer<Loaded>(
    for locale: Locale,
    load: (CatalogModel, URL) async throws -> Loaded
  ) async -> Loaded? {
    guard let id = selectedModelID else { return nil }
    guard let model = catalog.models.first(where: { $0.id == id }), runsOnThisSystem(model) else {
      return nil
    }
    if isBlocked(model) {
      report(.revoked(model.revoked?.reason ?? "no reason given"), for: model)
      return nil
    }
    let language = Self.catalogLanguage(of: locale)
    guard model.languages.contains(language) else {
      report(.unsupportedLanguage(language), for: model)
      return nil
    }
    let folder: URL
    do {
      folder = try await client.verify(model)
    } catch {
      report(RecognizerFallback(error: error), for: model)
      return nil
    }
    do {
      return try await load(model, folder)
    } catch {
      report(RecognizerFallback(error: error), for: model)
      return nil
    }
  }

  /// The catalog's language tag for `locale`: its bare language code.
  static func catalogLanguage(of locale: Locale) -> String {
    locale.language.languageCode?.identifier ?? locale.identifier
  }

  private func received(_ bytes: Int64, for id: String) {
    guard installs[id]?.stage == .download, installs[id]?.outcome == nil else { return }
    installs[id]?.receivedBytes = bytes
  }

  private func advance(_ id: String, to stage: InstallProgress.Stage) {
    guard var progress = installs[id] else { return }
    progress.stage = stage
    progress.stageStartedAt = now()
    if stage != .download { progress.receivedBytes = progress.totalBytes }
    installs[id] = progress
  }
}

/// One install's state, as the sheet and the row draw it.
struct InstallProgress: Equatable, Sendable {
  enum Stage: Int, CaseIterable, Sendable {
    case download, verify, prepare

    var title: String {
      switch self {
      case .download: "Download"
      case .verify: "Verify"
      case .prepare: "Prepare for the Neural Engine"
      }
    }
  }

  enum Outcome: Equatable, Sendable {
    case ready
    case failed(Stage, String)
  }

  var stage: Stage = .download
  var receivedBytes: Int64 = 0
  let totalBytes: Int64
  var stageStartedAt: Date
  var outcome: Outcome?

  init(
    stage: Stage = .download,
    receivedBytes: Int64 = 0,
    totalBytes: Int64,
    startedAt: Date,
    outcome: Outcome? = nil
  ) {
    self.stage = stage
    self.receivedBytes = receivedBytes
    self.totalBytes = totalBytes
    stageStartedAt = startedAt
    self.outcome = outcome
  }

  var downloadedFraction: Double {
    guard totalBytes > 0 else { return 0 }
    return min(1, Double(receivedBytes) / Double(totalBytes))
  }
}

/// Lets through one progress report per half percent: the installer reports every chunk,
/// thousands of them, and each report is a hop to the main actor.
private final class ProgressThrottle: Sendable {
  private let totalBytes: Int64
  private let lastStep = OSAllocatedUnfairLock(initialState: -1)

  init(totalBytes: Int64) {
    self.totalBytes = max(totalBytes, 1)
  }

  func shouldReport(_ received: Int64) -> Bool {
    let step = Int(received * 200 / totalBytes)
    return lastStep.withLock { last in
      guard step != last else { return false }
      last = step
      return true
    }
  }
}
