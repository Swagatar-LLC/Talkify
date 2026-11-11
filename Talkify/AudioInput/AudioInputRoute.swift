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
  var isDictationActive: Bool { lock.withLock { dictationActive } }

  /// Engine notifications can beat main-actor inventory notifications after
  /// unplugging a device. Resolve here too, rather than opening a stale ID.
  func deviceIDForCapture() throws -> AudioDeviceID? {
    guard lock.withLock({ enabled }) else { return nil }
    guard let readHardware else { return deviceID }
    let snapshot = try readHardware()
    let preferred = lock.withLock { preferredUID }
    return AudioInputSelection(
      preferredUID: preferred, devices: snapshot.devices, defaultDeviceID: snapshot.defaultDeviceID
    ).effectiveInput?.deviceID
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

  func publish(_ event: CaptureEvent) {
    let (state, handler) = lock.withLock {
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
    handler?(state)
  }
}
