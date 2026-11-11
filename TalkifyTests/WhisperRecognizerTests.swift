import AVFAudio
import Foundation
import Testing

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
