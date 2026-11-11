import AVFAudio
import Foundation
import Testing
@testable import Talkify

struct AudioInputLevelMonitorTests {
  final class Capture: AudioInputCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    var counts: (starts: Int, stops: Int) { lock.withLock { (starts, stops) } }
    func start(outputFormat: AVAudioFormat) throws { lock.withLock { starts += 1 } }
    func stop() { lock.withLock { stops += 1 } }
  }

  @Test func idleCaptureStopsBeforeDictationClaimsTheDeviceAndResumesAfterward() {
    let route = AudioInputRoute()
    let capture = Capture()
    let monitor = AudioInputLevelMonitor(route: route, makeCapture: { _, _ in capture })
    monitor.start()
    monitor.start()
    #expect(capture.counts.starts == 1)
    route.setDictationActive(true)
    #expect(capture.counts.stops == 1, "handoff is synchronous, not a queued suggestion")
    monitor.start()
    #expect(capture.counts.starts == 1, "Settings cannot interrupt dictation")
    route.setDictationActive(false)
    #expect(capture.counts.starts == 2)
    route.update(deviceID: 99)
    #expect(capture.counts.starts == 3)
    #expect(capture.counts.stops == 2)
    monitor.stop()
    monitor.stop()
    #expect(capture.counts.stops == 3)
    route.update(deviceID: 1)
    #expect(capture.counts.starts == 3, "closing Settings prevents hot-plug from reopening the mic")
  }

  @Test func closingSettingsDuringDictationDoesNotResumeAnIdleCaptureLater() {
    let route = AudioInputRoute()
    let capture = Capture()
    let monitor = AudioInputLevelMonitor(route: route, makeCapture: { _, _ in capture })
    route.setDictationActive(true)
    monitor.start()
    monitor.stop()
    route.setDictationActive(false)
    #expect(capture.counts.starts == 0)
    #expect(capture.counts.stops == 0)
  }
}
