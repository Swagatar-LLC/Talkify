import Foundation

/// The Recognizers a Direct Dictation session can run on, kept warm between sessions:
/// Apple Speech always, and the chosen Catalog Model once it has loaded.
///
/// A session takes its Recognizer when it starts and keeps it to the end, so a choice
/// changed in Settings mid-session applies to the next one (ADR-0004). A new choice
/// applies once its model has loaded and warmed. Until then sessions keep the previous
/// Recognizer, so no keypress waits on a load or loses its first words to one; after an
/// OS update that load can recompile for the Neural Engine for minutes.
///
/// Every Catalog Model failure, found while preparing or at the session's start, runs
/// that session on Apple Speech and posts the Settings notice that says why. Nothing
/// here downloads.
@MainActor
final class DictationRecognizers {
  /// Loads a Catalog Model from its verified folder, gives it `hints`, and runs it once,
  /// so its first session is warm.
  typealias Load = @MainActor (CatalogModel, URL, _ hints: [String]) async throws -> any Recognizer

  private let appleSpeech: any Recognizer
  private let store: RecognizerStore
  private let load: Load
  private let startCapture: RecognizerFeed.StartCapture
  /// The chosen Catalog Model as last prepared, or nil while Apple Speech is chosen.
  private(set) var preparation: CatalogPreparation<any Recognizer>?
  private var loading: (modelID: String, task: Task<Void, Never>)?
  private var hints: [String] = []
  /// The session in flight, from its start to its finish or cancel.
  private var session: RecognizerFeed?

  init(
    appleSpeech: any Recognizer,
    store: RecognizerStore,
    load: @escaping Load,
    startCapture: @escaping RecognizerFeed.StartCapture = RecognizerFeed.microphone
  ) {
    self.appleSpeech = appleSpeech
    self.store = store
    self.load = load
    self.startCapture = startCapture
  }

  /// The live load: the runtime the catalog entry names, which is WhisperKit for every
  /// entry so far. Install compiled the model for the Neural Engine; the prewarm here
  /// pays its first prediction, so the first session does not.
  static let loadCatalogModel: Load = { model, folder, hints in
    let recognizer = try await WhisperRecognizer.load(model: model, verifiedFolder: { folder })
    await recognizer.setHints(hints)
    try await recognizer.prewarm()
    return recognizer
  }

  /// The Vocabulary, for every warm Recognizer and the next one to load.
  func setHints(_ hints: [String]) async {
    self.hints = hints
    await appleSpeech.setHints(hints)
    if case .ready(_, let recognizer) = preparation {
      await recognizer.setHints(hints)
    }
  }

  /// Loads and warms the chosen Catalog Model, unless it is already the one warm or
  /// loading. A failed preparation is tried again, so files the user restores count at
  /// the next change. Choosing Apple Speech releases the model at once.
  func prepare() async {
    let chosen = store.selectedModelID
    if let loading, loading.modelID == chosen {
      await loading.task.value
      return
    }
    if case .ready(let model, _) = preparation, model.id == chosen { return }
    guard let chosen else {
      preparation = nil
      return
    }
    let task = Task { await prepare(chosen) }
    loading = (chosen, task)
    await task.value
  }

  private func prepare(_ modelID: String) async {
    defer { if loading?.modelID == modelID { loading = nil } }
    let hints = hints
    let load = load
    let result = await store.prepareChosenModel { model, folder in
      try await load(model, folder, hints)
    }
    // A choice changed while this loaded is the later preparation's to settle.
    guard store.selectedModelID == modelID else { return }
    preparation = result
    if case .ready(_, let recognizer) = result, self.hints != hints {
      await recognizer.setHints(self.hints)
    }
  }

  func start(
    locale: Locale,
    updateHandler: @escaping @Sendable (SpeechRecognitionService.Update) -> Void,
    failureHandler: @escaping @Sendable (String) -> Void,
    levelHandler: @escaping @Sendable (Float) -> Void
  ) async throws {
    // Held before the start is awaited, so a cancel that lands while the Recognizer is
    // still attaching finds the session to cancel.
    let feed = RecognizerFeed(recognizer: recognizer(for: locale), startCapture: startCapture)
    session = feed
    try await feed.start(
      locale: locale,
      updateHandler: updateHandler,
      failureHandler: failureHandler,
      levelHandler: levelHandler
    )
  }

  func finish() async throws -> String {
    guard let session else { throw SpeechRecognitionService.RecognitionError.noActiveSession }
    self.session = nil
    return try await session.finish()
  }

  func cancel() async {
    guard let session else { return }
    self.session = nil
    await session.cancel()
  }

  /// The Recognizer a session in `locale` runs on. A fallback posts its notice here, at
  /// the session it applies to.
  private func recognizer(for locale: Locale) -> any Recognizer {
    guard let preparation else { return appleSpeech }
    let language = RecognizerStore.catalogLanguage(of: locale)
    guard let fallback = preparation.fallback(forLanguage: language) else {
      if case .ready(_, let recognizer) = preparation { return recognizer }
      return appleSpeech
    }
    store.report(fallback, for: preparation.model)
    return appleSpeech
  }
}
