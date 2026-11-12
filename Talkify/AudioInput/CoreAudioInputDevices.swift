import CoreAudio
import Foundation

/// Enumeration and change notifications need no microphone permission and do
/// not open a capture stream. The OS default is read, never written.
enum CoreAudioInputDevices {
  struct Snapshot {
    let devices: [AudioInputDevice]
    let defaultDeviceID: AudioDeviceID?
  }

  struct QueryError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Audio input query failed (\(status))." }
  }

  static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
    )
  }

  static func snapshot() throws -> Snapshot {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var property = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size))
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    if !ids.isEmpty {
      let status = ids.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
      }
      try check(status)
    }
    var devices: [AudioInputDevice] = []
    for id in ids {
      var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
      var streamSize: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
        streamSize > 0,
        (try? scalar(id, selector: kAudioDevicePropertyDeviceIsAlive)) == 1,
        let uid = string(id, selector: kAudioDevicePropertyDeviceUID), !uid.isEmpty,
        let name = string(id, selector: kAudioObjectPropertyName)
      else { continue }
      devices.append(AudioInputDevice(id: uid, name: name, deviceID: id))
    }
    devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    let defaultID = try scalar(system, selector: kAudioHardwarePropertyDefaultInputDevice)
    return Snapshot(devices: devices, defaultDeviceID: defaultID == kAudioObjectUnknown ? nil : defaultID)
  }

  private static func scalar(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> UInt32 {
    var property = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value))
    return value
  }

  private static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: value))
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
    return value.map { $0.takeRetainedValue() as String }
  }

  static func check(_ status: OSStatus) throws {
    if status != noErr { throw QueryError(status: status) }
  }
}

/// Retains precisely the listener blocks used for removal. Releasing this
/// token (including during partial setup failure) unregisters every listener.
final class CoreAudioInputObservation {
  private var properties: [AudioObjectPropertyAddress] = []
  private let listener: AudioObjectPropertyListenerBlock

  init(onChange: @escaping @Sendable () -> Void) throws {
    listener = { _, _ in onChange() }
    for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
      var property = CoreAudioInputDevices.address(selector)
      try CoreAudioInputDevices.check(AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &property, .main, listener
      ))
      properties.append(property)
    }
  }

  deinit {
    for var property in properties {
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &property, .main, listener
      )
    }
  }
}
