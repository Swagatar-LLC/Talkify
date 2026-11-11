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
    let frameLength = max(1, Int((frameDuration * sampleRate).rounded()))
    let framesNeeded = max(1, Int((minimumSpeechDuration / frameDuration).rounded(.up)))
    let threshold = pow(10, thresholdDBFS / 20)
    let meanSquareThreshold = threshold * threshold

    var loudFrames = 0
    var start = 0
    while start + frameLength <= samples.count {
      var sum: Float = 0
      for index in start..<(start + frameLength) {
        sum += samples[index] * samples[index]
      }
      if sum / Float(frameLength) >= meanSquareThreshold {
        loudFrames += 1
        if loudFrames >= framesNeeded { return true }
      }
      start += frameLength
    }
    return false
  }
}
