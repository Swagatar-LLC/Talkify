import AVFoundation
import CoreAudio
import Observation

/// Settings binds directly to this model. Its idle meter yields the device to
/// Direct Dictation, then consumes that session's existing tap instead.
@MainActor
@Observable
final class AudioInputController {
  private let settings: AppSettings
  @ObservationIgnored private let requestMicrophoneAccess: @Sendable () async -> Bool
  @ObservationIgnored private var observation: CoreAudioInputObservation?
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var levelMonitor: AudioInputLevelMonitor?
  @ObservationIgnored private var lastCaptureEvent: UInt64 = 0
  @ObservationIgnored private var monitoringRequest: UInt64 = 0
  @ObservationIgnored private var monitoringRequested = false
  @ObservationIgnored private var listenerError: String?
  let route: AudioInputRoute

  private(set) var devices: [AudioInputDevice] = []
  private(set) var defaultDeviceID: AudioDeviceID?
  private(set) var selection = AudioInputSelection(preferredUID: nil, devices: [], defaultDeviceID: nil)
  private(set) var level: Float = 0
  private(set) var isMonitoring = false
  private(set) var captureError: String?
  private(set) var discoveryError: String?

  var preferredInputUID: String? { settings.preferredAudioInputUID }
  var effectiveInput: AudioInputDevice? { selection.effectiveInput }
  var isPreferredAvailable: Bool { selection.isPreferredAvailable }
  var isUsingSystem: Bool { selection.isUsingSystem }
  var microphoneAuthorization: AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  init(
    settings: AppSettings,
    observeHardware: Bool = true,
    requestMicrophoneAccess: @escaping @Sendable () async -> Bool = {
      await PermissionService.requestMicrophoneAccess()
    }
  ) {
    self.settings = settings
    self.requestMicrophoneAccess = requestMicrophoneAccess
    if observeHardware {
      route = AudioInputRoute(readHardware: { try CoreAudioInputDevices.snapshot() })
    } else {
      route = AudioInputRoute()
    }
    route.setCaptureHandler { [weak self] state in
      Task { @MainActor [weak self] in self?.receive(state) }
    }
    if observeHardware {
      do {
        observation = try CoreAudioInputObservation { [weak self] in
          Task { @MainActor [weak self] in self?.refresh() }
        }
      } catch {
        listenerError = error.localizedDescription
      }
      refresh()
    }
    resolveSelection()
    observePreference()
  }

  func selectInput(uid: String?) {
    guard !stopped else { return }
    settings.preferredAudioInputUID = uid
    resolveSelection()
  }

  func refresh() {
    guard !stopped else { return }
    do {
      let snapshot = try CoreAudioInputDevices.snapshot()
      discoveryError = listenerError
      updateInventory(devices: snapshot.devices, defaultDeviceID: snapshot.defaultDeviceID)
    } catch {
      discoveryError = error.localizedDescription
      updateInventory(devices: [], defaultDeviceID: nil)
    }
  }

  /// The deterministic boundary also lets tests simulate unplug/reconnect
  /// without a microphone or changing this Mac's system-wide default.
  func updateInventory(devices: [AudioInputDevice], defaultDeviceID: AudioDeviceID?) {
    guard !stopped else { return }
    self.devices = devices
    self.defaultDeviceID = defaultDeviceID
    resolveSelection()
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    observation = nil
    levelMonitor?.stop()
    levelMonitor = nil
    route.setCaptureHandler(nil)
    route.invalidate()
    isMonitoring = false
    level = 0
  }

  /// Call from the input Settings section's task, not at application launch.
  /// Permission is requested only for this explicit user-facing activity.
  func startMonitoring() async {
    guard !stopped else { return }
    monitoringRequest += 1
    let request = monitoringRequest
    monitoringRequested = true
    let allowed = await requestMicrophoneAccess()
    guard !stopped, monitoringRequested, request == monitoringRequest else { return }
    guard allowed else {
      captureError = "Microphone access is denied. Enable it in System Settings."
      return
    }
    if levelMonitor == nil { levelMonitor = AudioInputLevelMonitor(route: route) }
    levelMonitor?.start()
  }

  func stopMonitoring() {
    monitoringRequest += 1
    monitoringRequested = false
    levelMonitor?.stop()
    if !route.isDictationActive {
      isMonitoring = false
      level = 0
    }
  }

  private func resolveSelection() {
    selection = AudioInputSelection(
      preferredUID: preferredInputUID, devices: devices, defaultDeviceID: defaultDeviceID
    )
    route.update(deviceID: effectiveInput?.deviceID, preferredUID: preferredInputUID)
  }

  private func observePreference() {
    guard !stopped else { return }
    withObservationTracking {
      _ = settings.preferredAudioInputUID
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, !stopped else { return }
        resolveSelection()
        observePreference()
      }
    }
  }

  private func receive(_ state: AudioInputRoute.CaptureState) {
    guard !stopped, state.sequence > lastCaptureEvent else { return }
    lastCaptureEvent = state.sequence
    isMonitoring = state.isMonitoring && (monitoringRequested || route.isDictationActive)
    level = isMonitoring ? state.level : 0
    captureError = state.error
  }
}
