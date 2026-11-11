// Compile with the production audio sources; see docs/AudioInput.md.
import AVFoundation
import Foundation
import Speech

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
    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(64))
    let consumer = Task {
      for await _ in stream { counts.buffer() }
    }
    let input = MicrophoneInput(
      analyzerContinuation: continuation,
      failureHandler: { error in print("Capture failed: \(error.localizedDescription)") },
      route: route
    )
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    do {
      try input.start(outputFormat: format)
      try await Task.sleep(for: .seconds(1))
      input.stop()
      continuation.finish()
      await consumer.value
      try await Task.sleep(for: .seconds(1))
      monitor.stop()
    } catch {
      input.stop()
      continuation.finish()
      monitor.stop()
      consumer.cancel()
      throw error
    }
    let (buffers, levels, failures) = counts.values
    print("Real capture: \(buffers) analyzer buffers; \(levels) monitoring snapshots; \(failures.count) errors")
    precondition(buffers > 0 && levels > 0 && failures.isEmpty)
    precondition(!route.isDictationActive)
    print("Verified idle meter → dictation → idle meter handoff; audio was discarded, never saved")
  }
}
