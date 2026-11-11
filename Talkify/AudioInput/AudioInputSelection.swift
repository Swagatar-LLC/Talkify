import CoreAudio

struct AudioInputDevice: Identifiable, Equatable, Sendable {
  /// Core Audio's persistent UID, not its process-lifetime AudioDeviceID.
  let id: String
  let name: String
  let deviceID: AudioDeviceID
}

struct AudioInputSelection: Equatable, Sendable {
  let effectiveInput: AudioInputDevice?
  let isPreferredAvailable: Bool
  let isUsingSystem: Bool

  init(preferredUID: String?, devices: [AudioInputDevice], defaultDeviceID: AudioDeviceID?) {
    let preferred = preferredUID.flatMap { uid in devices.first { $0.id == uid } }
    isPreferredAvailable = preferredUID == nil || preferred != nil
    isUsingSystem = preferred == nil
    effectiveInput = preferred ?? devices.first { $0.deviceID == defaultDeviceID }
  }
}
