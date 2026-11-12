import CoreAudio
import Foundation

/// The only cross-thread routing state. Capture reads it before opening an
/// engine; the main actor updates it after resolving the user's preference.
final class AudioInputRoute: NSObject, @unchecked Sendable {
  static let didChange = Notification.Name("TalkifyAudioInputRouteDidChange")
  static let dictationActivityDidChange = Notification.Name("TalkifyDictationAudioActivityDidChange")

  enum CaptureEvent: Sendable {
    case started
    case level(Float)
    case stopped
    case failed(String)
  }

  struct CaptureState: Sendable {
    var sequence: UInt64 = 0
    var generation: UInt64 = 0
    var isMonitoring = false
    var level: Float = 0
    var error: String?
  }

  private let lock = NSLock()
  private var currentDeviceID: AudioDeviceID?
  private var preferredUID: String?
  private var enabled = true
  private let readHardware: (@Sendable () throws -> CoreAudioInputDevices.Snapshot)?
  private var dictationActive = false
  private var captureState = CaptureState()
  private var captureHandler: (@Sendable (CaptureState) -> Void)?

  init(readHardware: (@Sendable () throws -> CoreAudioInputDevices.Snapshot)? = nil) {
    self.readHardware = readHardware
  }

  var deviceID: AudioDeviceID? { lock.withLock { currentDeviceID } }
  var generation: UInt64 { lock.withLock { captureState.generation } }

  /// Each replacement tap owns its events; a retiring tap cannot light the
  /// meter under a different device's label.
  func beginCapture() -> UInt64 {
    let generation = lock.withLock {
      captureState.generation += 1
      return captureState.generation
    }
    publish(.stopped, generation: generation)
    return generation
  }
  var isDictationActive: Bool { lock.withLock { dictationActive } }

  /// Engine notifications can beat main-actor inventory notifications after
  /// unplugging a device. Resolve here too, rather than opening a stale ID.
  func deviceIDForCapture() throws -> AudioDeviceID? {
    guard lock.withLock({ enabled }) else { return nil }
    guard let readHardware else { return deviceID }
    let snapshot = try readHardware()
    return lock.withLock {
      guard enabled else { return nil }
      let resolved = AudioInputSelection(
        preferredUID: preferredUID, devices: snapshot.devices, defaultDeviceID: snapshot.defaultDeviceID
      ).effectiveInput?.deviceID
      // Recovery may beat inventory delivery. Remember its route so a quick
      // reconnect still notifies capture even if the UI never saw the outage.
      currentDeviceID = resolved
      return resolved
    }
  }

  /// Synchronous notification: an idle meter releases its microphone before
  /// dictation is allowed to open another engine on the same device.
  func setDictationActive(_ active: Bool) {
    let changed = lock.withLock {
      guard dictationActive != active else { return false }
      dictationActive = active
      return true
    }
    if changed { NotificationCenter.default.post(name: Self.dictationActivityDidChange, object: self) }
  }

  func update(deviceID: AudioDeviceID?, preferredUID: String? = nil) {
    let changed = lock.withLock {
      guard enabled else { return false }
      self.preferredUID = preferredUID
      guard currentDeviceID != deviceID else { return false }
      currentDeviceID = deviceID
      captureState.generation += 1
      captureState.isMonitoring = false
      captureState.level = 0
      captureState.error = nil
      return true
    }
    if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
  }

  func invalidate() {
    lock.withLock {
      enabled = false
      currentDeviceID = nil
    }
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }

  func setCaptureHandler(_ handler: (@Sendable (CaptureState) -> Void)?) {
    lock.withLock { captureHandler = handler }
  }

  func publish(_ event: CaptureEvent, generation: UInt64? = nil) {
    let delivery = lock.withLock { () -> (CaptureState, (@Sendable (CaptureState) -> Void)?)? in
      guard generation == nil || generation == captureState.generation else { return nil }
      captureState.sequence += 1
      switch event {
      case .started:
        captureState.isMonitoring = true
        captureState.level = 0
        captureState.error = nil
      case let .level(value):
        if captureState.isMonitoring {
          captureState.level = value.isFinite ? min(1, max(0, value)) : 0
        }
      case .stopped:
        captureState.isMonitoring = false
        captureState.level = 0
      case let .failed(message):
        captureState.isMonitoring = false
        captureState.level = 0
        captureState.error = message
      }
      return (captureState, captureHandler)
    }
    if let (state, handler) = delivery { handler?(state) }
  }
}
