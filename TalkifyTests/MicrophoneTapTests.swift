import AudioToolbox
import Synchronization
import Testing
@testable import Talkify

struct MicrophoneTapTests {
  @Test func oversizedNativeCallbackFailsWithoutRendering() throws {
    let ring = AUHALRing(unit: AudioUnit(bitPattern: 1)!, maximum: 1024, channels: 1,
      render: { _, _, _, _, _, _ in Issue.record("oversized callback rendered"); return -1 })
    let token = try AUHALAdmission.make(ring)
    defer { _ = token.state.bitwiseOr(1, ordering: .acquiringAndReleasing) }
    let callback = makeAUHALCallback(token)
    var flags: AudioUnitRenderActionFlags = []
    var timestamp = AudioTimeStamp()
    let status = callback.inputProc!(callback.inputProcRefCon!, &flags, &timestamp, 1, 1025, nil)
    #expect(status == kAudioUnitErr_TooManyFramesToProcess)
    #expect(ring.write.load(ordering: .acquiring) == 0)
  }
}
