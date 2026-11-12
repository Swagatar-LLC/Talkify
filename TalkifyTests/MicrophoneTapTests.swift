import AVFAudio
import Foundation
import Testing
@testable import Talkify

struct MicrophoneTapTests {
  #if compiler(>=6.4)
  @Test(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))))
  func rejectedTapReturnsAnErrorWithoutAbortingTheProcess() throws {
    let engine = AVAudioEngine()
    let mixer = AVAudioMixerNode()
    engine.attach(mixer)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    // A detached mixer exercises native tap rejection without opening a device.
    mixer.installTap(onBus: 0, bufferSize: 1_024, format: format) { _, _ in }
    defer { mixer.removeTap(onBus: 0) }
    #expect(throws: (any Error).self) {
      try MicrophoneInput.installTap(on: mixer) { _, _ in }
    }
  }
  #endif
}
