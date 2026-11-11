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
  private var requested = false
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
        queue.sync { reconcile(restart: restart) }
      }
      observers.append(observer)
    }
  }

  func start() {
    queue.sync {
      requested = true
      reconcile(restart: false)
    }
  }

  func stop() {
    queue.sync {
      requested = false
      reconcile(restart: false)
    }
  }

  private func reconcile(restart: Bool) {
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
