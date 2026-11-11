// Compile with the production audio sources; see docs/AudioInput.md.
import AVFoundation
import Foundation

@main
struct AudioInputProbe {
  final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var levels = 0
    private var failures: [String] = []
    func buffer() { lock.withLock { buffers += 1 } }
    func receive(_ state: AudioInputRoute.CaptureState) {
      lock.withLock {
        if state.isMonitoring { levels += 1 }
        if let error = state.error { failures.append(error) }
      }
    }
    var values: (Int, Int, [String]) { lock.withLock { (buffers, levels, failures) } }
  }

  static func main() async throws {
    let snapshot = try CoreAudioInputDevices.snapshot()
    let route = AudioInputRoute(readHardware: { try CoreAudioInputDevices.snapshot() })
    route.update(deviceID: snapshot.defaultDeviceID)
    let systemID = try route.deviceIDForCapture()
    print("Live inventory: \(snapshot.devices.count) input devices; System device: \(String(describing: systemID))")
    for device in snapshot.devices {
      route.update(deviceID: device.deviceID, preferredUID: device.id)
      let resolved = try route.deviceIDForCapture()
      precondition(resolved == device.deviceID)
    }
    route.update(deviceID: systemID, preferredUID: "Talkify-probe-missing-device")
    let fallback = try route.deviceIDForCapture()
    precondition(fallback == systemID)
    route.update(deviceID: systemID)
    print("Verified live UID resolution, System default, and missing-device fallback without modifying OS settings")
    guard CommandLine.arguments.contains("--capture") else { return }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      print("Capture UNVERIFIED: microphone permission is not already authorized; no permission prompt requested")
      return
    }
    guard systemID != nil else {
      print("Capture UNVERIFIED: no effective input")
      return
    }
    let counts = Counts()
    route.setCaptureHandler { counts.receive($0) }
    let monitor = AudioInputLevelMonitor(route: route)
    monitor.start()
    try await Task.sleep(for: .seconds(1))
    precondition(counts.values.1 > 1 && counts.values.2.isEmpty, "idle meter must receive real tap levels")
    let input = MicrophoneInput(
      feed: { _ in counts.buffer(); return true },
      failureHandler: { error in print("Capture failed: \(error.localizedDescription)") },
      route: route
    )
    // Use the integer PCM format requested by Apple Speech on macOS 27.
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
      sampleRate: 16_000, channels: 1, interleaved: false)!
    do {
      try input.start(outputFormat: format)
      try await Task.sleep(for: .seconds(1))
      precondition(counts.values.0 > 0, "dictation must receive Recognizer buffers")
      if CommandLine.arguments.contains("--switch") {
        for device in snapshot.devices { print("Available input: \(device.name) [\(device.deviceID)]") }
        guard let alternate = snapshot.devices.first(where: {
          $0.deviceID != systemID && $0.name.localizedCaseInsensitiveContains("MacBook")
        }) else {
          print("Live switch UNVERIFIED: no alternate built-in input was found")
          input.stop()
          monitor.stop()
          return
        }
        for (label, preferred) in [
          ("explicit input", alternate.id),
          ("missing UID fallback (simulated absence)", "Talkify-probe-missing-device"),
          ("preferred input restored (policy change, not physical reconnect)", alternate.id)
        ] {
          let before = counts.values
          let selection = AudioInputSelection(preferredUID: preferred,
            devices: snapshot.devices, defaultDeviceID: snapshot.defaultDeviceID)
          route.update(deviceID: selection.effectiveInput?.deviceID, preferredUID: preferred)
          // One retiring buffer is not proof the replacement tap is running.
          // Bluetooth teardown can also outlast a one-second sample window.
          for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(100))
            if (counts.values.0 >= before.0 + 3 && counts.values.1 >= before.1 + 3)
              || !counts.values.2.isEmpty { break }
          }
          let after = counts.values
          print("Active-capture \(label): \(after.0 - before.0) Recognizer buffers, \(after.1 - before.1) meter snapshots; failures \(after.2); resolved device \(String(describing: route.deviceID))")
          precondition(after.0 >= before.0 + 3 && after.1 >= before.1 + 3 && after.2.isEmpty)
        }
      }
      input.stop()
      let beforeIdleResume = counts.values.1
      try await Task.sleep(for: .seconds(1))
      precondition(counts.values.1 > beforeIdleResume, "idle meter must resume real tap levels")
      monitor.stop()
    } catch {
      input.stop()
      monitor.stop()
      throw error
    }
    let (buffers, levels, failures) = counts.values
    print("Real capture: \(buffers) Recognizer buffers; \(levels) monitoring snapshots; \(failures.count) errors")
    precondition(buffers > 0 && levels > 0 && failures.isEmpty)
    precondition(!route.isDictationActive)
    print("Verified idle meter → dictation → idle meter handoff; audio was discarded, never saved")
  }
}
