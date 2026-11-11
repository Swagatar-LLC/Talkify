import AVFAudio
import Foundation
import os
@testable import Talkify

/// A Recognizer that hears buffers instead of speech, and a capture that
/// hands it some, both writing to one log so the order between them is
/// visible: capture must stop before the Recognizer is told to end.
final class FakeRecognizer: Recognizer {
  struct CaptureFailure: LocalizedError {
    var errorDescription: String? { "no microphone" }
  }

  /// What the Recognizer asks to be fed: Whisper's own shape, so nothing
  /// here quietly depends on Apple's format.
  static let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!

  let log = OSAllocatedUnfairLock<[String]>(initialState: [])
  private let fedFrames = OSAllocatedUnfairLock<[AVAudioFrameCount]>(initialState: [])

  var entries: [String] { log.withLock { $0 } }

  func setHints(_ hints: [String]) async {
    log.withLock { $0.append("hints:\(hints.joined(separator: ","))") }
  }

  func start(
    locale: Locale,
    updateHandler: @escaping @Sendable (SpeechRecognitionService.Update) -> Void,
    beginFeeding: @Sendable (AVAudioFormat) throws -> Void
  ) async throws {
    log.withLock { $0.append("start:\(locale.identifier)") }
    try beginFeeding(Self.format)
    updateHandler(.init(finalizedText: "", volatileText: "heard"))
  }

  func feed(_ buffer: AVAudioPCMBuffer) -> Bool {
    let frames = buffer.frameLength
    let rate = Int(buffer.format.sampleRate)
    log.withLock { $0.append("feed:\(rate)") }
    fedFrames.withLock { $0.append(frames) }
    return true
  }

  func finish() async throws -> String {
    log.withLock { $0.append("finish") }
    let frames = fedFrames.withLock { $0.reduce(0, +) }
    return "heard \(frames) frames"
  }

  func cancel() async {
    log.withLock { $0.append("cancel") }
  }

  /// A capture that feeds `buffers` of 160 frames the moment it starts, or
  /// throws when `fails`, logging to the same place as the Recognizer.
  func capture(buffers: Int = 3, fails: Bool = false) -> RecognizerFeed.StartCapture {
    { [log] format, feed, _, _ in
      if fails { throw CaptureFailure() }
      log.withLock { $0.append("capture:\(Int(format.sampleRate))") }
      for _ in 0..<buffers {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        _ = feed(buffer)
      }
      return { log.withLock { $0.append("stopCapture") } }
    }
  }
}
