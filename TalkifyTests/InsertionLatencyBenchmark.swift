import AVFAudio
import Foundation
import os
import Testing

@testable import Talkify

/// The insertion latency benchmark (roadmap item 4): from the trigger's release to the
/// text reaching insertion, for Apple Speech and for the Whisper Catalog Model, over the
/// corpus clips. Each clip runs as a whole Direct Dictation session through the
/// controller, `DictationRecognizers` and `RecognizerFeed`; only the microphone is a
/// clip played into the feed at the speed it was spoken, and only the paste is a stand-in
/// that notes when the text arrived. A Recognizer that heard every word as it was spoken
/// is measured the way a microphone session would be, so the numbers compare.
///
/// Skipped unless `TALKIFY_LATENCY_CORPUS` names a folder of 16 kHz WAV clips. The
/// Whisper pass also needs `TALKIFY_WHISPERKIT_FIXTURES`, the folder holding
/// `openai_whisper-large-v3-v20240930_turbo_632MB/`. Optional:
/// `TALKIFY_LATENCY_VOCABULARY`, a file of Vocabulary terms one per line, likeliest last;
/// `TALKIFY_LATENCY_REPORT`, where the JSON report is written. Run through xcodebuild with
/// each name prefixed `TEST_RUNNER_`. It plays every clip in real time, twice: minutes.
@Suite(
  .enabled(if: ProcessInfo.processInfo.environment["TALKIFY_LATENCY_CORPUS"] != nil),
  .serialized
)
@MainActor
struct InsertionLatencyBenchmark {
  /// The gate this cycle set for a Catalog Model (ADR-9001).
  static let whisperP90Limit = Duration.seconds(1)

  struct Pass: Codable {
    var recognizer: String
    var clips: [Clip] = []
    var loadSeconds: Double?
    var p50Ms: Double = 0
    var p90Ms: Double = 0
    var maxMs: Double = 0
    var meanMs: Double = 0

    struct Clip: Codable {
      let name: String
      let audioSeconds: Double
      let releaseToInsertMs: Double
      let text: String
    }

    mutating func summarize() {
      let sorted = clips.map(\.releaseToInsertMs).sorted()
      p50Ms = Self.nearestRank(0.5, sorted)
      p90Ms = Self.nearestRank(0.9, sorted)
      maxMs = sorted.last ?? 0
      meanMs = sorted.reduce(0, +) / Double(max(sorted.count, 1))
    }

    static func nearestRank(_ quantile: Double, _ sorted: [Double]) -> Double {
      guard !sorted.isEmpty else { return 0 }
      let rank = Int((quantile * Double(sorted.count)).rounded(.up))
      return sorted[min(max(rank, 1), sorted.count) - 1]
    }
  }

  private var environment: [String: String] { ProcessInfo.processInfo.environment }

  @Test func keyReleaseToInsertionForBothRecognizers() async throws {
    let corpus = URL(filePath: try #require(environment["TALKIFY_LATENCY_CORPUS"]), directoryHint: .isDirectory)
    let clips = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "wav" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    try #require(!clips.isEmpty)
    let vocabulary = try environment["TALKIFY_LATENCY_VOCABULARY"].map {
      try String(contentsOfFile: $0, encoding: .utf8)
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    } ?? []

    var passes = [try await run(clips, vocabulary: vocabulary, whisperFolder: nil)]
    if let fixtures = environment["TALKIFY_WHISPERKIT_FIXTURES"] {
      passes.append(try await run(clips, vocabulary: vocabulary, whisperFolder: URL(filePath: fixtures)))
    }

    let report = try JSONEncoder.pretty.encode(passes)
    Attachment.record(String(decoding: report, as: UTF8.self), named: "insertion-latency.json")
    if let path = environment["TALKIFY_LATENCY_REPORT"] {
      try report.write(to: URL(filePath: path))
    }

    if let whisper = passes.first(where: { $0.recognizer == "whisper" }) {
      #expect(whisper.p90Ms <= Double(Self.whisperP90Limit.components.seconds) * 1000)
    }
  }

  /// Every clip as a held session, after one warm-up session that is not counted.
  private func run(_ clips: [URL], vocabulary: [String], whisperFolder: URL?) async throws -> Pass {
    let name = "InsertionLatencyBenchmark-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    let settings = AppSettings(defaults: defaults)
    settings.recognitionLocaleIdentifier = "en_US"
    settings.vocabularyTerms = vocabulary

    let catalog = try Catalog.bundled()
    let store = RecognizerStore(
      catalog: catalog,
      settings: settings,
      client: RecognizerStore.Client(
        isInstalled: { _ in true },
        download: { _, _ in Issue.record("the benchmark reached for the network") },
        // The fixture files are the catalog's pins (CatalogFixtureHashTests); the re-hash
        // runs before a load, never inside a session, so it is not what this measures.
        verify: { _ in try #require(whisperFolder) },
        prepare: { _, _ in },
        delete: { _ in }
      )
    )
    if whisperFolder != nil {
      settings.recognizerModelID = try #require(catalog.models.first { $0.runtime.id == WhisperRecognizer.runtimeID }).id
    }

    let player = ClipPlayer()
    let speechService = SpeechRecognitionService()
    let recognizers = DictationRecognizers(
      appleSpeech: speechService,
      store: store,
      load: DictationRecognizers.loadCatalogModel,
      startCapture: player.startCapture
    )
    let probe = InsertionProbe()
    let controller = DirectDictationController(
      settings: settings,
      dependencies: .benchmark(speechService: speechService, recognizers: recognizers, probe: probe)
    )

    var pass = Pass(recognizer: whisperFolder == nil ? "apple-speech" : "whisper")
    let clock = ContinuousClock()
    let loadStart = clock.now
    controller.applyLanguages()
    try await poll("preparation", timeout: .seconds(120)) { controller.isPreparedForTesting }
    if whisperFolder != nil {
      // A first load on a Mac compiles for the Neural Engine; Install pays that in the
      // app, and the benchmark waits it out here.
      try await poll("the Catalog Model to load", timeout: .seconds(900)) { recognizers.preparation != nil }
      guard case .ready = recognizers.preparation else {
        Issue.record("the Catalog Model failed to prepare: \(String(describing: recognizers.preparation))")
        return pass
      }
      pass.loadSeconds = Self.seconds(clock.now - loadStart)
    }

    _ = try await session(clips[0], controller: controller, player: player, probe: probe)
    for clip in clips {
      let (latency, text, audio) = try await session(clip, controller: controller, player: player, probe: probe)
      pass.clips.append(.init(
        name: clip.lastPathComponent, audioSeconds: audio,
        releaseToInsertMs: Self.seconds(latency) * 1000, text: text))
    }
    pass.summarize()
    controller.stop()
    return pass
  }

  /// One held session: press, play the clip as it was spoken, release at its end, and
  /// time the release to the text reaching insertion.
  private func session(
    _ clip: URL,
    controller: DirectDictationController,
    player: ClipPlayer,
    probe: InsertionProbe
  ) async throws -> (Duration, String, Double) {
    let audioSeconds = try player.load(clip)
    probe.reset()
    controller.handle(.triggerPressed(.primary))
    try await poll("the clip to play", timeout: .seconds(60)) { player.hasPlayedToTheEnd }
    let released = ContinuousClock.now
    controller.handle(.triggerReleased(.primary))
    try await poll("insertion", timeout: .seconds(30)) { probe.inserted != nil }
    let (insertedAt, text) = try #require(probe.inserted)
    try await poll("the session to end", timeout: .seconds(10)) { controller.sessionStateForTesting == .idle }
    // Apple Speech rebuilds its analyzer after each session; leave it the pause a person
    // leaves between two dictations.
    try await Task.sleep(for: .milliseconds(500))
    return (insertedAt - released, text, audioSeconds)
  }

  private func poll(_ what: String, timeout: Duration, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record("timed out waiting for \(what)")
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}

/// Notes when the session's text reached insertion, in place of the paste.
@MainActor
private final class InsertionProbe {
  private(set) var inserted: (ContinuousClock.Instant, String)?

  func reset() { inserted = nil }

  func insert(_ text: String) {
    inserted = (.now, text)
  }
}

/// A microphone that plays a clip: converted to the format the Recognizer asks for, in
/// buffers the size a 48 kHz microphone tap delivers, each handed over once the audio in
/// it would have been spoken.
private final class ClipPlayer: Sendable {
  private struct State {
    var clip: AVAudioPCMBuffer?
    var ended = false
  }

  private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

  /// Reads the clip the next session plays; returns its length in seconds.
  func load(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    state.withLockUnchecked { $0 = State(clip: buffer) }
    return Double(buffer.frameLength) / file.processingFormat.sampleRate
  }

  var hasPlayedToTheEnd: Bool { state.withLockUnchecked { $0.ended } }

  var startCapture: RecognizerFeed.StartCapture {
    { [state] format, feed, _, _ in
      let source = try #require(state.withLockUnchecked { $0.clip })
      nonisolated(unsafe) let audio = try Self.convert(source, to: format)
      let stopped = OSAllocatedUnfairLock(initialState: false)
      // 1,024 frames at 48 kHz, MicrophoneInput's tap, in the Recognizer's rate.
      let chunk = AVAudioFrameCount((format.sampleRate * 1024 / 48_000).rounded())
      let rate = format.sampleRate
      let thread = Thread {
        let start = Date()
        var offset: AVAudioFrameCount = 0
        while offset < audio.frameLength, !stopped.withLock({ $0 }) {
          let count = min(chunk, audio.frameLength - offset)
          Thread.sleep(until: start.addingTimeInterval(Double(offset + count) / rate))
          _ = feed(Self.slice(audio, from: offset, count: count))
          offset += count
        }
        state.withLockUnchecked { $0.ended = true }
      }
      thread.qualityOfService = .userInteractive
      thread.start()
      return { stopped.withLock { $0 = true } }
    }
  }

  private static func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    if source.format == format { return source }
    let converter = try #require(AVAudioConverter(from: source.format, to: format))
    let capacity = AVAudioFrameCount(Double(source.frameLength) * format.sampleRate / source.format.sampleRate) + 1_024
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
    let given = OSAllocatedUnfairLock(initialState: false)
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if given.withLock({ $0 }) {
        inputStatus.pointee = .endOfStream
        return nil
      }
      given.withLock { $0 = true }
      inputStatus.pointee = .haveData
      return source
    }
    if let error { throw error }
    try #require(status != .error)
    return output
  }

  private static func slice(_ audio: AVAudioPCMBuffer, from offset: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: audio.format, frameCapacity: count)!
    buffer.frameLength = count
    let bytesPerFrame = Int(audio.format.streamDescription.pointee.mBytesPerFrame)
    let source = UnsafeMutableAudioBufferListPointer(audio.mutableAudioBufferList)
    let target = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    for (from, to) in zip(source, target) {
      memcpy(to.mData, from.mData! + Int(offset) * bytesPerFrame, Int(count) * bytesPerFrame)
    }
    return buffer
  }
}

extension DirectDictationController.Dependencies {
  /// The session path with nothing faked but the microphone and the paste: speech runs
  /// as `live` runs it, and everything a person would see or hear is silent.
  @MainActor
  fileprivate static func benchmark(
    speechService: SpeechRecognitionService,
    recognizers: DictationRecognizers,
    probe: InsertionProbe
  ) -> Self {
    Self(
      setDownloadHandler: { await speechService.setDownloadHandler($0) },
      resolveLocale: { try await speechService.resolveLocale(identifier: $0) },
      supportedLocale: { await speechService.supportedLocale(identifier: $0) },
      retainOnly: { await speechService.retainOnly(locales: $0) },
      setVocabulary: { await recognizers.setHints($0) },
      prewarm: { try await speechService.prewarm(locale: $0) },
      prepareRecognizer: { await recognizers.prepare() },
      startRecognition: { locale, updateHandler, failureHandler, levelHandler in
        try await recognizers.start(
          locale: locale, updateHandler: updateHandler, failureHandler: failureHandler, levelHandler: levelHandler)
      },
      finishRecognition: { try await recognizers.finish() },
      cancelRecognition: { await recognizers.cancel() },
      shutDownRecognition: {
        await recognizers.cancel()
        await speechService.shutDown()
      },
      translation: TranslationCoordinator(
        service: TranslationService(
          client: TranslationService.Client(
            availability: { _ in .unsupported },
            prepare: { _ in },
            translate: { _, text in text },
            candidateTargets: { [] },
            retain: { _ in },
            shutDown: {}
          )
        )
      ),
      captureFocusedTarget: {
        TextInsertionService.Target(
          element: nil, processIdentifier: 1, isSecure: false, displayID: nil, applicationName: "Benchmark")
      },
      insertText: { text, _, _ in
        probe.insert(text)
        return .inserted
      },
      requestMicrophoneAccess: { true },
      requestSpeechAccess: { true },
      requestAccessibilityAccess: {},
      hasAccessibilityAccess: { true },
      isPermissionAlertPresenting: { false },
      showAccessibilitySetupAlert: {},
      showRelaunchAlert: {},
      showListening: { _, _, _, _ in },
      showLatched: {},
      showLiveText: { _, _ in },
      showFinalizing: {},
      showShaping: { _ in },
      showShapingChoice: { _ in },
      showMessage: { message, _ in Issue.record("the HUD said: \(message)") },
      showModelDownload: { _ in },
      showAudioLevel: { _ in },
      hideHUD: {},
      playPasteSound: {},
      setShapingCycleCaptureEnabled: { _ in },
      recordSession: { _, _ in },
      recordHistory: { _, _, _, _ in },
      shapeText: { text, _ in text }
    )
  }
}

extension JSONEncoder {
  fileprivate static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
