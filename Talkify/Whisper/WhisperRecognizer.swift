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
/// Whisper hears a whole session at once rather than streaming, so a session posts no
/// draft text: the words arrive when `finish` returns. Audio that never reaches the
/// voice-activity gate returns no text without running the model.
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

  /// The catalog's runtime id for this adapter.
  static let runtimeID = "whisperkit"

  let model: CatalogModel
  let gate: VoiceActivityGate
  private let kit: WhisperKit
  private let tokenizer: any WhisperTokenizer
  private var promptTokens: [Int]?
  private var activeLanguage = "en"
  /// The session's audio so far, or nil outside a session. Written on the audio thread.
  private let samples = OSAllocatedUnfairLock<[Float]?>(initialState: nil)

  private init(model: CatalogModel, gate: VoiceActivityGate, kit: WhisperKit, tokenizer: any WhisperTokenizer) {
    self.model = model
    self.gate = gate
    self.kit = kit
    self.tokenizer = tokenizer
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
    _ = try await kit.transcribe(
      audioArray: [Float](repeating: 0, count: Int(Self.sampleRate)) + Self.trailingPad,
      decodeOptions: decodingOptions(language: model.languages.first ?? "en")
    )
  }

  func setHints(_ hints: [String]) async {
    guard let text = WhisperPrompt.text(for: hints) else {
      promptTokens = nil
      return
    }
    // Encoded as WhisperKit's own command line does: a leading space, and no special tokens.
    let specialTokenBegin = tokenizer.specialTokens.specialTokenBegin
    promptTokens = tokenizer.encode(text: " " + text).filter { $0 < specialTokenBegin }
  }

  func start(
    locale: Locale,
    updateHandler: @escaping @Sendable (SpeechRecognitionService.Update) -> Void,
    beginFeeding: @Sendable (AVAudioFormat) throws -> Void
  ) async throws {
    guard samples.withLock({ $0 }) == nil else { throw Failure.sessionAlreadyActive }
    let language = Self.language(of: locale)
    guard model.languages.contains(language) else {
      throw Failure.unsupportedLanguage(locale.identifier)
    }
    activeLanguage = language
    samples.withLock { $0 = [] }
    do {
      try beginFeeding(Self.format)
    } catch {
      samples.withLock { $0 = nil }
      throw error
    }
  }

  /// Copies the buffer into the session. False once the session is over its length cap.
  nonisolated func feed(_ buffer: AVAudioPCMBuffer) -> Bool {
    guard let channel = buffer.floatChannelData?[0], buffer.format.sampleRate == Self.sampleRate else {
      return false
    }
    let frames = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
    let cap = Int(Self.maximumSessionDuration * Self.sampleRate)
    return samples.withLockUnchecked { samples in
      // A buffer with no session to hear it is dropped quietly, as Apple's path does.
      guard samples != nil else { return true }
      guard samples!.count + frames.count <= cap else { return false }
      samples!.append(contentsOf: frames)
      return true
    }
  }

  func finish() async throws -> String {
    guard let audio = samples.withLock({ samples in
      defer { samples = nil }
      return samples
    }) else {
      throw Failure.noActiveSession
    }
    guard gate.containsSpeech(audio, sampleRate: Self.sampleRate) else { return "" }

    let results = try await kit.transcribe(
      audioArray: audio + Self.trailingPad,
      decodeOptions: decodingOptions(language: activeLanguage)
    )
    return results
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// Silence added after the session's audio. WhisperKit stops decoding one second
  /// (`windowClipTime`) short of the end, so a clipped tail cannot set off a hallucination;
  /// without the pad a one-word session under a second long would return nothing, and the
  /// last second of every session would rest on that rule. Whisper pads its 30 s window
  /// with zeros anyway, so a session that fits one window sees the same input.
  private static let trailingPad = [Float](repeating: 0, count: Int(sampleRate))

  func cancel() async {
    samples.withLock { $0 = nil }
  }

  private func decodingOptions(language: String) -> DecodingOptions {
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
