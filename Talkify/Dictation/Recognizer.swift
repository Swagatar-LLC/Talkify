import AVFAudio
import Foundation
import os

/// What turns a Direct Dictation session's audio into text: Apple Speech, or
/// a Catalog Model the user installed.
///
/// The microphone is not part of it. `RecognizerFeed` owns the capture and
/// feeds whichever Recognizer the session uses, so a route change, a dead
/// input, or a level meter behaves the same whoever is listening.
protocol Recognizer: Sendable {
  /// Words to expect, ordered likeliest last, held until replaced.
  ///
  /// Applied wherever the Recognizer prepares rather than on the keypress, so
  /// the warm path stays warm. Failing to apply one never fails a session.
  func setHints(_ hints: [String]) async

  /// Opens a session in `locale`.
  ///
  /// `beginFeeding` runs once, with the format `feed` expects, as soon as
  /// audio can be queued and before the Recognizer has finished attaching:
  /// a Bluetooth input can take hundreds of milliseconds to wake, and those
  /// early buffers are speech. A throw from it fails the start.
  func start(
    locale: Locale,
    updateHandler: @escaping @Sendable (SpeechRecognitionService.Update) -> Void,
    beginFeeding: @Sendable (AVAudioFormat) throws -> Void
  ) async throws

  /// One buffer in the format `start` asked for, on the audio thread.
  /// False when it was dropped because recognition fell behind.
  func feed(_ buffer: AVAudioPCMBuffer) -> Bool

  /// Ends the session and returns everything it heard.
  func finish() async throws -> String

  /// Ends the session and discards it.
  func cancel() async
}

/// One session's audio path: capture in, Recognizer out.
///
/// Capture stops before the Recognizer is told to finish or cancel, so the
/// last buffer it hears is the last one captured, never one that arrives
/// after the end of input.
final class RecognizerFeed: Sendable {
  /// Starts capturing, converted into `format`, handing each buffer to
  /// `feed`. Returns what stops it.
  typealias StartCapture = @Sendable (
    _ format: AVAudioFormat,
    _ feed: @escaping @Sendable (AVAudioPCMBuffer) -> Bool,
    _ failureHandler: @escaping @Sendable (String) -> Void,
    _ levelHandler: @escaping @Sendable (Float) -> Void
  ) throws -> @Sendable () -> Void

  let recognizer: any Recognizer
  private let startCapture: StartCapture
  private let stopCapture = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

  init(recognizer: any Recognizer, startCapture: @escaping StartCapture = RecognizerFeed.microphone) {
    self.recognizer = recognizer
    self.startCapture = startCapture
  }

  func start(
    locale: Locale,
    updateHandler: @escaping @Sendable (SpeechRecognitionService.Update) -> Void,
    failureHandler: @escaping @Sendable (String) -> Void,
    levelHandler: @escaping @Sendable (Float) -> Void
  ) async throws {
    let recognizer = recognizer
    let startCapture = startCapture
    let stopCapture = stopCapture
    do {
      try await recognizer.start(locale: locale, updateHandler: updateHandler) { format in
        let stop = try startCapture(
          format,
          { recognizer.feed($0) },
          failureHandler,
          levelHandler
        )
        stopCapture.withLock { $0 = stop }
      }
    } catch {
      stopFeeding()
      throw error
    }
  }

  func finish() async throws -> String {
    stopFeeding()
    return try await recognizer.finish()
  }

  func cancel() async {
    stopFeeding()
    await recognizer.cancel()
  }

  private func stopFeeding() {
    let stop = stopCapture.withLock { stop in
      defer { stop = nil }
      return stop
    }
    stop?()
  }

  /// The live capture: the Mac's microphone.
  static let microphone: StartCapture = microphone(route: nil)

  static func microphone(route: AudioInputRoute?) -> StartCapture {
    { format, feed, failureHandler, levelHandler in
    let input = MicrophoneInput(
      feed: feed,
      failureHandler: { failureHandler($0.localizedDescription) },
      levelHandler: levelHandler,
      route: route
    )
    try input.start(outputFormat: format)
    return { input.stop() }
    }
  }
}
