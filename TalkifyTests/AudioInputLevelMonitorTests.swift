import AVFAudio
import Foundation
import Testing
@testable import Talkify

struct AudioInputLevelMonitorTests {
  final class Capture: AudioInputCapturing, @unchecked Sendable {
    private let condition = NSCondition()
    private var starts = 0
    private var stops = 0
    var counts: (starts: Int, stops: Int) { condition.withLock { (starts, stops) } }

    func start(outputFormat: AVAudioFormat) throws {
      condition.withLock {
        starts += 1
        condition.broadcast()
      }
    }

    func stop() {
      condition.withLock {
        stops += 1
        condition.broadcast()
      }
    }

    func waitForStarts(_ count: Int) -> Bool {
      wait { starts >= count }
    }

    func waitForStops(_ count: Int) -> Bool {
      wait { stops >= count }
    }

    private func wait(until predicate: () -> Bool) -> Bool {
      condition.lock()
      defer { condition.unlock() }
      let deadline = Date(timeIntervalSinceNow: 3)
      while !predicate() {
        if !condition.wait(until: deadline) { return predicate() }
      }
      return true
    }
  }

  @Test func idleCaptureStopsBeforeDictationClaimsTheDeviceAndResumesAfterward() {
    let route = AudioInputRoute()
    let capture = Capture()
    let monitor = AudioInputLevelMonitor(route: route, makeCapture: { _, _ in capture })
    monitor.start()
    monitor.start()
    #expect(capture.waitForStarts(1))
    #expect(capture.counts.starts == 1)
    route.setDictationActive(true)
    #expect(capture.counts.stops == 1, "handoff is synchronous, not a queued suggestion")
    monitor.start()
    #expect(capture.counts.starts == 1, "Settings cannot interrupt dictation")
    route.setDictationActive(false)
    #expect(capture.waitForStarts(2))
    #expect(capture.counts.starts == 2)
    route.update(deviceID: 99)
    #expect(capture.waitForStarts(3))
    #expect(capture.counts.starts == 3)
    #expect(capture.counts.stops == 2)
    monitor.stop()
    monitor.stop()
    #expect(capture.waitForStops(3))
    #expect(capture.counts.stops == 3)
    route.update(deviceID: 1)
    route.setDictationActive(true)
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
    route.setDictationActive(true)
    #expect(capture.counts.starts == 0)
    #expect(capture.counts.stops == 0)
  }
}
