import AVFAudio
import Foundation
import Testing
import os

@testable import Talkify

struct VoiceActivityGateTests {
  private let rate = 16_000.0
  private let gate = VoiceActivityGate()

  private func tone(dBFS: Float, seconds: Double) -> [Float] {
    // A sine's RMS is its peak over root two.
    let amplitude = Float(pow(10, Double(dBFS) / 20) * 2.squareRoot())
    return (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
  }

  @Test func silenceIsNotSpeech() {
    #expect(!gate.containsSpeech([Float](repeating: 0, count: Int(3 * rate)), sampleRate: rate))
    #expect(!gate.containsSpeech([], sampleRate: rate))
  }

  @Test func steadyNoiseBelowTheThresholdIsNotSpeech() {
    // The corpus's low-noise clip sits at -41 dBFS.
    #expect(!gate.containsSpeech(tone(dBFS: -41, seconds: 3), sampleRate: rate))
  }

  @Test func soundAboveTheThresholdIsSpeech() {
    #expect(gate.containsSpeech(tone(dBFS: -25, seconds: 1), sampleRate: rate))
  }

  @Test func aClickShorterThanTheMinimumIsNotSpeech() {
    let quiet = [Float](repeating: 0, count: Int(rate))
    let click = tone(dBFS: -10, seconds: 0.06)
    #expect(!gate.containsSpeech(quiet + click + quiet, sampleRate: rate))
  }

  @Test func shortBurstsAddUpToSpeech() {
    let gap = [Float](repeating: 0, count: Int(0.2 * rate))
    let burst = tone(dBFS: -25, seconds: 0.06)
    #expect(gate.containsSpeech(Array([burst, gap, burst, gap, burst].joined()), sampleRate: rate))
  }

  /// The detector a session feeds buffer by buffer reaches the same verdict as the
  /// gate over the whole session, at whatever buffer size, frames straddling buffers.
  @Test(arguments: [1, 160, 479, 1_600, 4_096])
  func theStreamingDetectorAgreesWithTheWholeSessionGate(bufferSize: Int) {
    let quiet = [Float](repeating: 0, count: Int(0.5 * rate))
    let sessions: [[Float]] = [
      quiet,
      tone(dBFS: -41, seconds: 1),
      quiet + tone(dBFS: -25, seconds: 0.5),
      quiet + tone(dBFS: -10, seconds: 0.06) + quiet,
      Array([tone(dBFS: -25, seconds: 0.06), quiet, tone(dBFS: -25, seconds: 0.06), quiet,
             tone(dBFS: -25, seconds: 0.06)].joined()),
    ]
    for session in sessions {
      var detector = VoiceActivityGate.Detector(gate: gate, sampleRate: rate)
      var heard = false
      for start in stride(from: 0, to: session.count, by: bufferSize) {
        let chunk = Array(session[start..<min(start + bufferSize, session.count)])
        heard = chunk.withUnsafeBufferPointer { detector.hear($0) }
      }
      #expect(heard == gate.containsSpeech(session, sampleRate: rate))
      #expect(detector.hasHeardSpeech == heard)
    }
  }
}

struct WhisperRecognizerDraftTests {
  private func makeRecognizer(
    transcribe: @escaping WhisperRecognizer.Decode = { _, _, _ in "draft" }
  ) throws -> WhisperRecognizer {
    let model = try #require(try Catalog.bundled().models.first { $0.runtime.id == WhisperRecognizer.runtimeID })
    return WhisperRecognizer(model: model, tokenize: { Array(repeating: 1, count: $0.count) }, transcribe: transcribe)
  }

  private func audio(seconds: Double = 1, value: Float = 0.1) -> AVAudioPCMBuffer {
    let count = AVAudioFrameCount(seconds * WhisperRecognizer.sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: WhisperRecognizer.format, frameCapacity: count)!
    buffer.frameLength = count
    buffer.floatChannelData![0].update(repeating: value, count: Int(count))
    return buffer
  }

  @Test func cancelledDraftsCannotPublishIntoTheNextSession() async throws {
    let state = OSAllocatedUnfairLock(initialState: (active: 0, maximum: 0, calls: 0, oldTexts: [String](), newTexts: [String]()))
    let recognizer = try makeRecognizer { _, _, _ in
      let call = state.withLock { state in
        state.active += 1
        state.maximum = max(state.maximum, state.active)
        state.calls += 1
        return state.calls
      }
      try await Task.sleep(for: .milliseconds(100))
      state.withLock { $0.active -= 1 }
      return "draft \(call)"
    }
    try await recognizer.start(locale: Locale(identifier: "en"), updateHandler: { update in
      state.withLock { $0.oldTexts.append(update.volatileText) }
    }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio()))
    for _ in 0..<100 {
      if state.withLock({ $0.active == 1 }) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(state.withLock { $0.active == 1 })
    await recognizer.cancel()
    try await recognizer.start(locale: Locale(identifier: "en"), updateHandler: { update in
      state.withLock { $0.newTexts.append(update.volatileText) }
    }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio()))
    for _ in 0..<100 {
      if state.withLock({ $0.newTexts.contains("draft 2") }) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(state.withLock { $0.oldTexts.allSatisfy(\.isEmpty) })
    #expect(state.withLock { $0.newTexts == ["", "draft 2"] })
    #expect(state.withLock { $0.maximum == 1 })
    await recognizer.cancel()
  }

  @Test func silenceAndSubthresholdAudioNeverInvokeTheDecoder() async throws {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let recognizer = try makeRecognizer { _, _, _ in
      calls.withLock { $0 += 1 }
      return "hallucination"
    }
    try await recognizer.start(locale: Locale(identifier: "en"), updateHandler: { _ in }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio(value: 0)))
    #expect(recognizer.feed(audio(value: 0.001)))
    #expect(try await recognizer.finish() == "")
    #expect(calls.withLock { $0 == 0 })
  }

  @Test func repeatedDraftsUseRecentAudioWhileFinishKeepsTheFullSession() async throws {
    let calls = OSAllocatedUnfairLock(initialState: [(count: Int, first: Float)]())
    let recognizer = try makeRecognizer { samples, _, _ in
      calls.withLock { $0.append((samples.count, samples[0])) }
      return "text"
    }
    try await recognizer.start(locale: Locale(identifier: "en"), updateHandler: { _ in }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio(seconds: 15, value: 0.1)))
    try await Task.sleep(for: .milliseconds(100))
    #expect(calls.withLock { $0.count == 1 })
    #expect(recognizer.feed(audio(seconds: 15, value: 0.2)))
    try await Task.sleep(for: .milliseconds(100))
    #expect(calls.withLock { $0.count == 2 })
    #expect(try await recognizer.finish() == "text")
    #expect(calls.withLock { $0.map(\.count) == [96_000, 96_000, 496_000] })
    #expect(calls.withLock { $0.map(\.first) == [0.1, 0.2, 0.1] })
  }

  @Test func vocabularyBudgetAndLanguageReachBothDraftAndFinalDecode() async throws {
    let options = OSAllocatedUnfairLock(initialState: [(tokens: [Int], language: String?)]())
    let recognizer = try makeRecognizer { _, language, tokens in
      options.withLock { $0.append((tokens ?? [], language)) }
      return "text"
    }
    await recognizer.setHints(Array(repeating: "Vocabulary", count: 100))
    let planned = await recognizer.promptTokens
    #expect((planned?.count ?? 0) <= 93)
    #expect(planned?.isEmpty == false)
    try await recognizer.start(locale: Locale(identifier: "en_US"), updateHandler: { _ in }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio()))
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await recognizer.finish() == "text")
    #expect(options.withLock { $0.count == 2 })
    #expect(options.withLock { $0.allSatisfy { $0.tokens == planned && $0.language == "en" } })
  }

  @Test func sessionDurationCapStillRejectsLaterAudio() async throws {
    let sizes = OSAllocatedUnfairLock(initialState: [Int]())
    let recognizer = try makeRecognizer { samples, _, _ in
      sizes.withLock { $0.append(samples.count) }
      return "text"
    }
    try await recognizer.start(locale: Locale(identifier: "en"), updateHandler: { _ in }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio(seconds: WhisperRecognizer.maximumSessionDuration)))
    #expect(!recognizer.feed(audio(seconds: 0.01)))
    #expect(try await recognizer.finish() == "text")
    #expect(sizes.withLock { $0.last == 9_616_000 })
    #expect(sizes.withLock { $0.dropLast().allSatisfy { $0 <= 96_000 } })
  }

  @Test func aDraftFailureDoesNotPreventFinalTranscription() async throws {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let recognizer = try makeRecognizer { _, _, _ in
      let call = calls.withLock { $0 += 1; return $0 }
      if call == 1 { throw CancellationError() }
      return "complete"
    }
    try await recognizer.start(locale: Locale(identifier: "en"), updateHandler: { _ in }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio()))
    try await Task.sleep(for: .milliseconds(100))
    #expect(calls.withLock { $0 == 1 })
    #expect(try await recognizer.finish() == "complete")
  }

  @Test func cancellingAFinishRejectsItsLateTextWithoutOverlappingTheNextSession() async throws {
    let state = OSAllocatedUnfairLock(initialState: (active: 0, maximum: 0, calls: 0))
    let recognizer = try makeRecognizer { _, _, _ in
      let call = state.withLock { state in
        state.active += 1
        state.maximum = max(state.maximum, state.active)
        state.calls += 1
        return state.calls
      }
      try await Task.sleep(for: .milliseconds(200))
      state.withLock { $0.active -= 1 }
      return "result \(call)"
    }
    try await recognizer.start(locale: Locale(identifier: "en"), updateHandler: { _ in }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio(seconds: 0.3)))
    let oldFinish = Task { try await recognizer.finish() }
    for _ in 0..<100 {
      if state.withLock({ $0.active == 1 }) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(state.withLock { $0.active == 1 })
    await recognizer.cancel()
    try await recognizer.start(locale: Locale(identifier: "en"), updateHandler: { _ in }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio(seconds: 0.3)))
    #expect(try await recognizer.finish() == "result 2")
    await #expect(throws: CancellationError.self) { try await oldFinish.value }
    #expect(state.withLock { $0.maximum == 1 })
  }

  @Test func silenceAfterSpeechDoesNotDecodeTheOldWordsAgain() async throws {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let recognizer = try makeRecognizer { _, _, _ in
      calls.withLock { $0 += 1 }
      return "draft"
    }
    try await recognizer.start(locale: Locale(identifier: "en"), updateHandler: { _ in }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio()))
    try await Task.sleep(for: .milliseconds(100))
    #expect(calls.withLock { $0 == 1 })
    #expect(recognizer.feed(audio(value: 0)))
    try await Task.sleep(for: .milliseconds(100))
    #expect(calls.withLock { $0 == 1 })
    await recognizer.cancel()
  }

  @Test func finishWaitsForDraftAndStillDecodesAllSessionAudio() async throws {
    let state = OSAllocatedUnfairLock(initialState: (active: 0, maximum: 0, sizes: [Int]()))
    let recognizer = try makeRecognizer { samples, _, _ in
      let call = state.withLock { state in
        state.active += 1
        state.maximum = max(state.maximum, state.active)
        state.sizes.append(samples.count)
        return state.sizes.count
      }
      try await Task.sleep(for: .milliseconds(250))
      state.withLock { $0.active -= 1 }
      return call == 1 ? "draft" : "complete"
    }
    try await recognizer.start(locale: Locale(identifier: "en"), updateHandler: { _ in }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio(seconds: 20)))
    for _ in 0..<100 {
      if state.withLock({ $0.active > 0 }) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(state.withLock { $0.active == 1 })
    #expect(try await recognizer.finish() == "complete")
    #expect(state.withLock { $0.maximum == 1 })
    #expect(state.withLock { $0.sizes == [96_000, 336_000] })
  }

  @Test func speechPublishesAVolatileDraftBeforeFinish() async throws {
    let updates = OSAllocatedUnfairLock<[SpeechRecognitionService.Update]>(initialState: [])
    let recognizer = try makeRecognizer()
    try await recognizer.start(locale: Locale(identifier: "en"), updateHandler: { update in
      updates.withLock { $0.append(update) }
    }, beginFeeding: { _ in })
    #expect(recognizer.feed(audio()))
    try await Task.sleep(for: .milliseconds(150))
    #expect(updates.withLock { $0.contains { $0.finalizedText.isEmpty && $0.volatileText == "draft" } })
    await recognizer.cancel()
  }
}

struct WhisperRecognizerLoadTests {
  private func whisperEntry() throws -> CatalogModel {
    try #require(try Catalog.bundled().models.first { $0.runtime.id == WhisperRecognizer.runtimeID })
  }

  @Test func theWhisperEntryLoadsFromTheFolderHoldingItsTokenizer() throws {
    #expect(try whisperEntry().whisperModelPath == "openai_whisper-large-v3-v20240930_turbo_632MB")
  }

  @Test func aFailedReHashStopsTheLoadBeforeWhisperKitRuns() async throws {
    let model = try whisperEntry()
    await #expect(throws: CatalogInstallError.hashMismatch(path: "x")) {
      _ = try await WhisperRecognizer.load(model: model) { throw CatalogInstallError.hashMismatch(path: "x") }
    }
  }

  @Test func anEntryForAnotherRuntimeIsRefusedWithoutReadingAFile() async throws {
    var model = try whisperEntry()
    model.runtime.id = "fluidaudio"
    await #expect(throws: WhisperRecognizer.Failure.unsupportedModel) {
      _ = try await WhisperRecognizer.load(model: model) {
        Issue.record("the folder was verified for a model that cannot load")
        return URL(filePath: "/nonexistent")
      }
    }
  }

  @Test func anInstalledFolderMissingItsModelsFailsAsALoadError() async throws {
    let model = try whisperEntry()
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "WhisperRecognizerLoadTests-" + UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: folder.appending(path: try #require(model.whisperModelPath)), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    do {
      _ = try await WhisperRecognizer.load(model: model) { folder }
      Issue.record("loaded a folder with no model in it")
    } catch let failure as WhisperRecognizer.Failure {
      guard case .loadFailed = failure else {
        Issue.record("expected loadFailed, got \(failure)")
        return
      }
    }
  }

  @Test func catalogLanguageIsTheLocalesLanguageCode() {
    #expect(WhisperRecognizer.language(of: Locale(identifier: "en_US")) == "en")
    #expect(WhisperRecognizer.language(of: Locale(identifier: "de-DE")) == "de")
  }
}
