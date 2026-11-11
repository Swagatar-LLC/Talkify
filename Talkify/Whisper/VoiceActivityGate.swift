import Foundation

/// Whether a session's audio holds anything loud enough to be speech, decided before
/// Whisper sees it.
///
/// Whisper writes words for silence: the spike heard "Thank you." from three seconds of
/// it once the Vocabulary was in the prompt. A session the gate turns away ends with no
/// text instead of a sentence nobody spoke.
///
/// It is an energy gate and nothing cleverer. The audio is cut into short frames, and the
/// session counts as speech once enough of them reach the threshold. The defaults sit
/// above the synthetic corpus's steady noise (-41 dBFS) and 13 dB under its quietest
/// spoken frame; WhisperKit's own energy detector uses -34 dBFS. Real-voice numbers from
/// the soak decide whether they hold for a quiet speaker on a laptop microphone.
struct VoiceActivityGate: Equatable, Sendable {
  /// Length of one measured frame, in seconds.
  var frameDuration: Double = 0.03
  /// Root-mean-square level a frame must reach to count, in dBFS.
  var thresholdDBFS: Float = -38
  /// How much audio, summed across frames, must reach the threshold.
  var minimumSpeechDuration: Double = 0.15

  func containsSpeech(_ samples: [Float], sampleRate: Double) -> Bool {
    var detector = Detector(gate: self, sampleRate: sampleRate)
    return samples.withUnsafeBufferPointer { detector.hear($0) }
  }

  /// The same rule, applied to audio as it arrives: buffer after buffer, with a frame
  /// allowed to straddle two of them. Whisper posts no draft text, so this is how a
  /// session says it has heard someone before it finishes.
  struct Detector: Sendable {
    private let frameLength: Int
    private let framesNeeded: Int
    private let meanSquareThreshold: Float
    private var loudFrames = 0
    private var frameSum: Float = 0
    private var frameFill = 0

    init(gate: VoiceActivityGate, sampleRate: Double) {
      frameLength = max(1, Int((gate.frameDuration * sampleRate).rounded()))
      framesNeeded = max(1, Int((gate.minimumSpeechDuration / gate.frameDuration).rounded(.up)))
      let threshold = pow(10, gate.thresholdDBFS / 20)
      meanSquareThreshold = threshold * threshold
    }

    /// Whether the audio heard so far counts as speech.
    var hasHeardSpeech: Bool { loudFrames >= framesNeeded }

    /// Hears `samples` after everything before them; true once the audio so far is speech.
    mutating func hear(_ samples: UnsafeBufferPointer<Float>) -> Bool {
      for sample in samples {
        guard !hasHeardSpeech else { break }
        frameSum += sample * sample
        frameFill += 1
        guard frameFill == frameLength else { continue }
        if frameSum / Float(frameLength) >= meanSquareThreshold { loudFrames += 1 }
        frameSum = 0
        frameFill = 0
      }
      return hasHeardSpeech
    }
  }
}
