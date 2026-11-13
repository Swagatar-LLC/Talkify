import AVFAudio
import Foundation
import os
@preconcurrency import WhisperKit

/// Whisper large-v3-turbo as a Recognizer, run in process on Core ML through WhisperKit.
///
/// This folder is the only place WhisperKit is imported, the way Sparkle stays in
/// `Updates/`. Everything it loads comes from the installer's verified folder: the
/// catalog's pinned files, hashed again just before the load. WhisperKit never fetches;
/// its downloader is switched off and the tokenizer is built here from the verified
/// `tokenizer.json`, so its fall-back download from the Hugging Face Hub is never reached.
///
/// Drafts repeatedly decode a bounded recent window; only `finish` decodes the whole
/// session. Silence never reaches the model, and drafts never become insertion text.
actor WhisperRecognizer: Recognizer {
  enum Failure: LocalizedError, Equatable, Sendable {
    /// The catalog entry is not one this runtime can load.
    case unsupportedModel
    case unsupportedLanguage(String)
    /// WhisperKit or Core ML refused the verified files.
    case loadFailed(String)
    case sessionAlreadyActive
    case noActiveSession

    var errorDescription: String? {
      switch self {
      case .unsupportedModel:
        "This model is not a Whisper model Talkify can load."
      case .unsupportedLanguage(let language):
        "The selected model is not listed for \(language)."
      case .loadFailed(let reason):
        "The selected model failed to load: \(reason)"
      case .sessionAlreadyActive:
        "A dictation session is already running."
      case .noActiveSession:
        "There is no dictation session to finish."
      }
    }
  }

  /// What `feed` takes: Whisper's own input, 16 kHz mono floats.
  static let sampleRate: Double = 16_000
  static let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: sampleRate,
    channels: 1,
    interleaved: false
  )!
  /// The longest session kept, in seconds; later audio is dropped and reported so.
  static let maximumSessionDuration: Double = 600
  static let draftWindowDuration: Double = 5
  static let draftInterval: Double = 1

  /// The catalog's runtime id for this adapter.
  static let runtimeID = "whisperkit"

  let model: CatalogModel
  let gate: VoiceActivityGate
  typealias Decode = @Sendable ([Float], String, [Int]?) async throws -> String
  private enum Runtime {
    case live(WhisperKit, any WhisperTokenizer)
    case injected(@Sendable (String) -> [Int], Decode)
  }
  private let runtime: Runtime
  /// The prompt line the planner chose for the current hints, and its tokens.
  private(set) var prompt: String?
  private(set) var promptTokens: [Int]?
  private var activeLanguage = "en"
  private var currentSessionID: UUID?
  private var decoding = false
  private var decodeWaiters: [CheckedContinuation<Void, Never>] = []
  /// One session's audio so far, and what the gate has made of it.
  private struct Session {
    let id = UUID()
    var samples: [Float] = []
    var detector: VoiceActivityGate.Detector
    var draftDetector: VoiceActivityGate.Detector
    var draftPending = false
    var draftedSampleCount = 0
    let updateHandler: @Sendable (SpeechRecognitionService.Update) -> Void
  }
  /// The session in flight, or nil outside one. Written on the audio thread.
  private let session = OSAllocatedUnfairLock<Session?>(initialState: nil)

  init(
    model: CatalogModel,
    gate: VoiceActivityGate = VoiceActivityGate(),
    tokenize: @escaping @Sendable (String) -> [Int],
    transcribe: @escaping Decode
  ) {
    self.model = model
    self.gate = gate
    self.runtime = .injected(tokenize, transcribe)
  }

  private init(model: CatalogModel, gate: VoiceActivityGate, kit: WhisperKit, tokenizer: any WhisperTokenizer) {
    self.model = model
    self.gate = gate
    self.runtime = .live(kit, tokenizer)
  }

  /// Loads `model` from the folder `verifiedFolder` returns, which must re-hash every
  /// pinned file first: `CatalogInstaller.verifiedFolder(for:)` in the app.
  ///
  /// The first load on a Mac pays Core ML's Neural Engine compile (157 s in the spike);
  /// Install pays it, so a dictation never does.
  static func load(
    model: CatalogModel,
    gate: VoiceActivityGate = VoiceActivityGate(),
    verifiedFolder: @Sendable () throws -> URL
  ) async throws -> WhisperRecognizer {
    guard model.runtime.id == runtimeID, let modelPath = model.whisperModelPath else {
      throw Failure.unsupportedModel
    }
    let folder = try verifiedFolder().appending(path: modelPath, directoryHint: .isDirectory)

    do {
      // WhisperKit falls back to downloading a tokenizer when the local one fails to
      // parse. Parsing it here first, with the same call and the same files, means a bad
      // tokenizer fails the load before WhisperKit can reach for the network.
      _ = try await AutoTokenizerWrapper.from(
        modelFolder: folder,
        hubApi: HubApiWrapper(downloadBase: folder)
      )
      let kit = try await WhisperKit(WhisperKitConfig(
        modelFolder: folder.path,
        tokenizerFolder: folder,
        verbose: false,
        logLevel: .error,
        prewarm: false,
        load: false,
        download: false
      ))
      try await kit.loadModels()
      guard let tokenizer = kit.tokenizer else { throw WhisperError.tokenizerUnavailable() }
      return WhisperRecognizer(model: model, gate: gate, kit: kit, tokenizer: tokenizer)
    } catch {
      throw Failure.loadFailed(String(describing: error))
    }
  }

  /// Runs the model once on a second of silence, past the gate, so the first session
  /// does not pay for Core ML's first prediction.
  func prewarm() async throws {
    _ = try await decode(
      [Float](repeating: 0, count: Int(Self.sampleRate)) + Self.trailingPad,
      language: model.languages.first ?? "en"
    )
  }

  func setHints(_ hints: [String]) async {
    prompt = HintPlanner.whisperPrompt(for: hints) { encodePrompt($0).count }
    promptTokens = prompt.map(encodePrompt)
  }

  /// `text` encoded as WhisperKit's own command line does: a leading space, and no
  /// special tokens. The planner's token budget is counted with this same encoding.
  private func encodePrompt(_ text: String) -> [Int] {
    switch runtime {
    case .live(_, let tokenizer):
      tokenizer.encode(text: " " + text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    case .injected(let tokenize, _):
      tokenize(text)
    }
  }

  func start(
    locale: Locale,
    updateHandler: @escaping @Sendable (SpeechRecognitionService.Update) -> Void,
    beginFeeding: @Sendable (AVAudioFormat) throws -> Void
  ) async throws {
    guard session.withLock({ $0 == nil }) else { throw Failure.sessionAlreadyActive }
    let language = Self.language(of: locale)
    guard model.languages.contains(language) else {
      throw Failure.unsupportedLanguage(locale.identifier)
    }
    activeLanguage = language
    let detector = VoiceActivityGate.Detector(gate: gate, sampleRate: Self.sampleRate)
    let started = Session(detector: detector, draftDetector: detector, updateHandler: updateHandler)
    currentSessionID = started.id
    session.withLock { $0 = started }
    do {
      try beginFeeding(Self.format)
    } catch {
      session.withLock { $0 = nil }
      currentSessionID = nil
      throw error
    }
  }

  /// Copies the buffer into the session. False once the session is over its length cap.
  /// The buffer that first makes the session speech posts the update that says so.
  nonisolated func feed(_ buffer: AVAudioPCMBuffer) -> Bool {
    guard let channel = buffer.floatChannelData?[0], buffer.format.sampleRate == Self.sampleRate else {
      return false
    }
    let frames = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
    let cap = Int(Self.maximumSessionDuration * Self.sampleRate)
    var heard: (@Sendable (SpeechRecognitionService.Update) -> Void)?
    var draftID: UUID?
    let kept = session.withLockUnchecked { session in
      // A buffer with no session to hear it is dropped quietly, as Apple's path does.
      guard session != nil else { return true }
      guard session!.samples.count + frames.count <= cap else { return false }
      session!.samples.append(contentsOf: frames)
      if !session!.detector.hasHeardSpeech, session!.detector.hear(frames) {
        heard = session!.updateHandler
      }
      _ = session!.draftDetector.hear(frames)
      if session!.draftDetector.hasHeardSpeech, !session!.draftPending,
         session!.samples.count - session!.draftedSampleCount >= Int(Self.draftInterval * Self.sampleRate) {
        session!.draftPending = true
        draftID = session!.id
      }
      return true
    }
    heard?(.init(finalizedText: "", volatileText: "", heardSpeech: true))
    if let draftID { Task { await refreshDraft(id: draftID) } }
    return kept
  }

  private func refreshDraft(id: UUID) async {
    let samples = session.withLock { session -> [Float]? in
      guard session?.id == id else { return nil }
      session!.draftedSampleCount = session!.samples.count
      session!.draftDetector = VoiceActivityGate.Detector(gate: gate, sampleRate: Self.sampleRate)
      return Array(session!.samples.suffix(Int(Self.draftWindowDuration * Self.sampleRate)))
    }
    guard let samples else { return }
    defer {
      session.withLock { session in
        if session?.id == id { session!.draftPending = false }
      }
    }
    guard gate.containsSpeech(samples, sampleRate: Self.sampleRate) else { return }
    guard let text = try? await decode(
      samples + Self.trailingPad, language: activeLanguage, sessionID: id, draft: true),
          !text.isEmpty else { return }
    let handler = session.withLock { session in
      session?.id == id ? session?.updateHandler : nil
    }
    handler?(.init(finalizedText: "", volatileText: text, heardSpeech: false))
  }

  func finish() async throws -> String {
    guard let ended = session.withLock({ session in
      defer { session = nil }
      return session
    }) else {
      throw Failure.noActiveSession
    }
    guard ended.detector.hasHeardSpeech else { return "" }

    let text = try await decode(
      ended.samples + Self.trailingPad, language: activeLanguage, sessionID: ended.id)
    guard currentSessionID == ended.id else { throw CancellationError() }
    try Task.checkCancellation()
    return text
  }

  private func decode(
    _ samples: [Float], language: String, sessionID: UUID? = nil, draft: Bool = false
  ) async throws -> String {
    let tokens = promptTokens
    if decoding {
      await withCheckedContinuation { decodeWaiters.append($0) }
    } else {
      decoding = true
    }
    defer {
      if decodeWaiters.isEmpty { decoding = false } else { decodeWaiters.removeFirst().resume() }
    }
    try Task.checkCancellation()
    if let sessionID {
      guard currentSessionID == sessionID,
            !draft || session.withLock({ $0?.id == sessionID }) else { throw CancellationError() }
    }
    // Cancellation cannot free the model until its actual prediction has returned.
    switch runtime {
    case .live(let kit, _):
      return try await kit.transcribe(
        audioArray: samples, decodeOptions: Self.decodingOptions(language: language, promptTokens: tokens))
        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    case .injected(_, let transcribe):
      return try await transcribe(samples, language, tokens)
    }
  }

  /// Silence added after the session's audio. WhisperKit stops decoding one second
  /// (`windowClipTime`) short of the end, so a clipped tail cannot set off a hallucination;
  /// without the pad a one-word session under a second long would return nothing, and the
  /// last second of every session would rest on that rule. Whisper pads its 30 s window
  /// with zeros anyway, so a session that fits one window sees the same input.
  private static let trailingPad = [Float](repeating: 0, count: Int(sampleRate))

  func cancel() async {
    currentSessionID = nil
    session.withLock { $0 = nil }
  }

  private static func decodingOptions(language: String, promptTokens: [Int]?) -> DecodingOptions {
    var options = DecodingOptions(
      task: .transcribe,
      language: language,
      temperature: 0,
      usePrefillPrompt: true,
      skipSpecialTokens: true,
      withoutTimestamps: true,
      // Past Whisper's 30 s window, split at pauses so each piece decodes whole. Without
      // it a 42 s session came back with only its first 30 s.
      chunkingStrategy: .vad
    )
    options.promptTokens = promptTokens
    return options
  }

  /// The catalog's language tag for `locale`: its bare language code.
  static func language(of locale: Locale) -> String {
    locale.language.languageCode?.identifier ?? locale.identifier
  }
}
