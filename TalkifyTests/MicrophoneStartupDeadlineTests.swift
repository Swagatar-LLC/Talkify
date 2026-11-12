import Testing
@testable import Talkify

struct MicrophoneStartupDeadlineTests {
  @Test func aStartedCaptureWithNoFirstBufferExpiresOnlyOnce() {
    var startup = MicrophoneInput.StartupDeadline()
    let generation = startup.begin()
    let expired = startup.expire(generation: generation)
    #expect(expired)
    let duplicate = startup.expire(generation: generation)
    #expect(!duplicate)
  }

  @Test func silenceIsABufferButAnEmptyCallbackIsNot() {
    var startup = MicrophoneInput.StartupDeadline()
    let empty = startup.begin()
    startup.receive(frameCount: 0, generation: empty)
    let expired = startup.expire(generation: empty)
    #expect(expired)
    let silence = startup.begin()
    startup.receive(frameCount: 1_024, generation: silence)
    let silenceExpired = startup.expire(generation: silence)
    #expect(!silenceExpired)
  }

  @Test func cancelledAndReplacedDeadlinesCannotFailANewerCapture() {
    var startup = MicrophoneInput.StartupDeadline()
    let cancelled = startup.begin()
    startup.cancel()
    let cancelledExpired = startup.expire(generation: cancelled)
    #expect(!cancelledExpired)
    let retired = startup.begin()
    let replacement = startup.begin()
    startup.receive(frameCount: 1_024, generation: retired)
    let retiredExpired = startup.expire(generation: retired)
    #expect(!retiredExpired)
    let replacementExpired = startup.expire(generation: replacement)
    #expect(replacementExpired)
  }

  @Test func aBufferDeliveredInsideSynchronousStartSatisfiesStartup() {
    var startup = MicrophoneInput.StartupDeadline()
    let generation = startup.begin()
    startup.receive(frameCount: 1_024, generation: generation)
    let expired = startup.expire(generation: generation)
    #expect(!expired)
  }
}
