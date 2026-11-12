import AVFAudio
import Foundation
import Testing
@testable import Talkify

struct AudioInputResponsivenessTests {
  final class BlockedCapture: AudioInputCapturing, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var owners = 0
    private var maximumOwners = 0
    private var startedOnMain = false
    private var timedOut = false

    var state: (starts: Int, stops: Int, owners: Int, maximumOwners: Int, startedOnMain: Bool, timedOut: Bool) {
      lock.withLock { (starts, stops, owners, maximumOwners, startedOnMain, timedOut) }
    }

    func start(outputFormat: AVAudioFormat) throws {
      lock.withLock {
        starts += 1
        owners += 1
        maximumOwners = max(maximumOwners, owners)
        startedOnMain = Thread.isMainThread
      }
      entered.signal()
      let result = release.wait(timeout: .now() + 5)
      lock.withLock { timedOut = result == .timedOut }
    }

    func stop() {
      lock.withLock {
        stops += 1
        owners -= 1
      }
      stopped.signal()
    }
  }

  @Test func repeatedMonitoringRequestsKeepTheInFlightStartup() {
    let route = AudioInputRoute()
    let capture = BlockedCapture()
    let monitor = AudioInputLevelMonitor(route: route, makeCapture: { _, _ in capture })
    monitor.start()
    #expect(capture.entered.wait(timeout: .now() + 3) == .success)
    monitor.start()
    monitor.start()
    // Permit any erroneous replacement to finish too, so RED cannot hang.
    capture.release.signal()
    capture.release.signal()
    let stoppedBeforeClose = capture.stopped.wait(timeout: .now() + 0.2)
    #expect(stoppedBeforeClose == .timedOut, "identical requests must not retire an in-flight startup")
    monitor.stop()
    route.setDictationActive(true)
    #expect(capture.state.starts == 1)
    #expect(capture.state.stops == 1)
    #expect(capture.state.owners == 0)
    #expect(capture.state.maximumOwners == 1)
    #expect(!capture.state.timedOut)
  }

  @Test func idleCaptureResumesAndRefreshesEventuallyWithoutOverlappingOwners() {
    let route = AudioInputRoute()
    let capture = BlockedCapture()
    let monitor = AudioInputLevelMonitor(route: route, makeCapture: { _, _ in capture })
    capture.release.signal()
    monitor.start()
    #expect(capture.entered.wait(timeout: .now() + 3) == .success)
    route.setDictationActive(true)
    #expect(capture.state.stops == 1, "the lease releases synchronously")
    capture.release.signal()
    route.setDictationActive(false)
    #expect(capture.entered.wait(timeout: .now() + 3) == .success)
    capture.release.signal()
    route.update(deviceID: 99)
    #expect(capture.entered.wait(timeout: .now() + 3) == .success)
    monitor.stop()
    route.setDictationActive(true)
    #expect(capture.state.starts == 3)
    #expect(capture.state.stops == 3)
    #expect(capture.state.owners == 0)
    #expect(capture.state.maximumOwners == 1)
    #expect(!capture.state.timedOut)
  }

  @Test func dictationLeaseWaitsForBlockedStartupToReleaseItsOnlyOwner() {
    let route = AudioInputRoute()
    let capture = BlockedCapture()
    let monitor = AudioInputLevelMonitor(route: route, makeCapture: { _, _ in capture })
    monitor.start()
    #expect(capture.entered.wait(timeout: .now() + 3) == .success)
    let leaseRequested = DispatchSemaphore(value: 0)
    let leaseGranted = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      leaseRequested.signal()
      route.setDictationActive(true)
      leaseGranted.signal()
    }
    #expect(leaseRequested.wait(timeout: .now() + 3) == .success)
    let grantedBeforeRelease = leaseGranted.wait(timeout: .now() + 0.1)
    capture.release.signal()
    #expect(leaseGranted.wait(timeout: .now() + 3) == .success)
    #expect(grantedBeforeRelease == .timedOut, "dictation cannot open while idle startup owns capture")
    #expect(capture.state.starts == 1)
    #expect(capture.state.stops == 1)
    #expect(capture.state.owners == 0)
    #expect(capture.state.maximumOwners == 1)
    #expect(!capture.state.timedOut)
    monitor.stop()
    route.setDictationActive(false)
    route.setDictationActive(true)
    #expect(capture.state.starts == 1, "closing during dictation cancels queued idle resume")
  }

  @Test func settingsRequestsReturnWhileStartupIsBlockedAndClosingPreventsStaleReopen() {
    let route = AudioInputRoute()
    let capture = BlockedCapture()
    let monitor = AudioInputLevelMonitor(route: route, makeCapture: { _, _ in capture })
    let startedRequest = DispatchSemaphore(value: 0)
    let closedRequest = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
      monitor.start()
      startedRequest.signal()
    }
    #expect(capture.entered.wait(timeout: .now() + 3) == .success)
    let startReturned = startedRequest.wait(timeout: .now() + 1)
    DispatchQueue.main.async {
      route.update(deviceID: 99)
      monitor.stop()
      route.update(deviceID: 100)
      closedRequest.signal()
    }
    let closeReturned = closedRequest.wait(timeout: .now() + 1)
    // Release even on RED so the regression fails without hanging the test host.
    capture.release.signal()
    #expect(startReturned == .success || startedRequest.wait(timeout: .now() + 3) == .success)
    #expect(closeReturned == .success || closedRequest.wait(timeout: .now() + 3) == .success)
    // Dictation's synchronous lease is a finite drain of all earlier meter work.
    route.setDictationActive(true)
    #expect(startReturned == .success, "Settings startup must not wait for capture.start")
    #expect(closeReturned == .success, "route refresh and closing must not wait for capture.start")
    #expect(!capture.state.startedOnMain)
    #expect(!capture.state.timedOut)
    #expect(capture.state.starts == 1, "retired route requests cannot reopen capture after closing")
    #expect(capture.state.stops == 1)
    #expect(capture.state.owners == 0, "dictation owns the device only after idle capture is released")
    #expect(capture.state.maximumOwners == 1)
  }
}
