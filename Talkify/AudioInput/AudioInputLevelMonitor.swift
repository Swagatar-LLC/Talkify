import AVFAudio
import Foundation

/// The hardware boundary for deterministic ownership/handoff tests.
protocol AudioInputCapturing: AnyObject, Sendable {
  func start(outputFormat: AVAudioFormat) throws
  func stop()
}

extension MicrophoneInput: AudioInputCapturing {}

/// A level-only use of the same capture owner as dictation. It releases the
/// device synchronously before dictation starts, then uses dictation's levels
/// until that session ends. No two engines compete for a Bluetooth input.
final class AudioInputLevelMonitor: @unchecked Sendable {
  private let route: AudioInputRoute
  private let makeCapture: @Sendable (
    AudioInputRoute, @escaping @Sendable (MicrophoneInput.InputError) -> Void
  ) -> any AudioInputCapturing
  private let queue = DispatchQueue(label: "com.tgomareli.Talkify.input-meter")
  private var observers: [any NSObjectProtocol] = []
  private let requestLock = NSLock()
  private var requested = false
  private var requestGeneration: UInt64 = 0
  private var restartRequested = false
  private var capture: (any AudioInputCapturing)?
  private var captureID: UUID?

  init(
    route: AudioInputRoute,
    makeCapture: @escaping @Sendable (
      AudioInputRoute, @escaping @Sendable (MicrophoneInput.InputError) -> Void
    ) -> any AudioInputCapturing = { route, failure in
      MicrophoneInput(failureHandler: failure, route: route)
    }
  ) {
    self.route = route
    self.makeCapture = makeCapture
    for name in [AudioInputRoute.didChange, AudioInputRoute.dictationActivityDidChange] {
      let observer = NotificationCenter.default.addObserver(
        forName: name, object: route, queue: nil
      ) { [weak self] notification in
        let restart = notification.name == AudioInputRoute.didChange
        guard let self else { return }
        // Only Direct Dictation's lease waits for release, on its recognizer
        // executor. Settings and route notifications must never wait for HAL.
        request(restart: restart, synchronous: !restart && route.isDictationActive)
      }
      observers.append(observer)
    }
  }

  func start() {
    request(monitoring: true)
  }

  func stop() {
    request(monitoring: false)
  }

  private func request(monitoring: Bool? = nil, restart: Bool = false, synchronous: Bool = false) {
    let generation = requestLock.withLock { () -> UInt64? in
      // Repeated Settings presentations must not retire a startup already in
      // flight. Notifications still reconcile, and a lease always drains work.
      if let monitoring, requested == monitoring, !restart, !synchronous { return nil }
      if let monitoring { requested = monitoring }
      requestGeneration += 1
      restartRequested = restartRequested || restart
      return requestGeneration
    }
    guard let generation else { return }
    let work: @Sendable () -> Void = { [self] in
      let state = requestLock.withLock { () -> (requested: Bool, restart: Bool)? in
        guard generation == requestGeneration else { return nil }
        defer { restartRequested = false }
        return (requested, restartRequested)
      }
      guard let state else { return }
      reconcile(requested: state.requested, restart: state.restart, generation: generation)
    }
    if synchronous {
      // This barrier must release even if another UI request supersedes it.
      queue.sync {
        capture?.stop()
        capture = nil
        captureID = nil
      }
    } else {
      queue.async(execute: work)
    }
  }

  private func reconcile(requested: Bool, restart: Bool, generation: UInt64) {
    let shouldCapture = requested && !route.isDictationActive
    if capture != nil, shouldCapture, !restart { return }
    capture?.stop()
    capture = nil
    captureID = nil
    guard shouldCapture else { return }
    let id = UUID()
    let input = makeCapture(route, { [weak self] _ in
      guard let self else { return }
      queue.async { [weak self] in
        guard let self, captureID == id else { return }
        capture?.stop()
        capture = nil
        captureID = nil
      }
    })
    capture = input
    captureID = id
    do {
      // A level-only capture does not resample or feed a SpeechAnalyzer.
      guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else { return }
      try input.start(outputFormat: format)
      // stop/route requests can arrive while a driver blocks in start. Retire
      // that capture before any queued request can claim a replacement.
      if requestLock.withLock({ generation != requestGeneration }) || route.isDictationActive {
        input.stop()
        capture = nil
        captureID = nil
      }
    } catch {
      capture = nil
      captureID = nil
    }
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    capture?.stop()
  }
}
