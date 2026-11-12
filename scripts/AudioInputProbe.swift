// Compile with the production audio sources; see docs/AudioInput.md.
import AVFoundation
import Foundation

@main
struct AudioInputProbe {
  struct CaptureCheckFailed: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func requireCapture(_ condition: Bool, _ message: String) throws {
    if !condition { throw CaptureCheckFailed(message: message) }
  }

  static func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }

  static func outcome(checkpointPassed: Bool, satisfied: Bool, hasErrors: Bool) -> String {
    if hasErrors { return "capture-failed" }
    if !satisfied { return "persistent-stall-at-bound" }
    return checkpointPassed ? "within-one-second" : "late-recovery-in-same-process"
  }

  final class Counts: @unchecked Sendable {
    struct Snapshot {
      var buffers: [TimeInterval] = []
      var levels: [TimeInterval] = []
      var failures: [String] = []
    }
    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var previousState = AudioInputRoute.CaptureState()
    func buffer(at instant: TimeInterval = ProcessInfo.processInfo.systemUptime) {
      lock.withLock { snapshot.buffers.append(instant) }
    }
    func receive(_ state: AudioInputRoute.CaptureState,
      at instant: TimeInterval = ProcessInfo.processInfo.systemUptime) {
      lock.withLock {
        // .started lights the meter but is not an audio callback.
        if state.isMonitoring, previousState.isMonitoring, state.generation == previousState.generation {
          snapshot.levels.append(instant)
        }
        if let error = state.error, error != previousState.error { snapshot.failures.append(error) }
        previousState = state
      }
    }
    var values: Snapshot { lock.withLock { snapshot } }
  }

  /// Keep the failed one-second checkpoint and continue observing this owner,
  /// not a fresh process. The bound starts after the synchronous operation.
  @MainActor
  @discardableResult
  static func observe(_ label: String, counts: Counts, needsBuffers: Bool,
    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    operation: () throws -> Void) async throws -> String {
    let before = counts.values
    let began = now()
    try operation()
    let returned = now()
    log("\(label): synchronous operation returned after \(returned - began)s")
    let checkpointCutoff = returned + 1
    let finalCutoff = returned + 30
    // Sleep only schedules observation. Callback timestamps decide membership,
    // including callbacks during synchronous startup (negative relative times).
    func samples(through cutoff: TimeInterval) -> Counts.Snapshot {
      let value = counts.values
      return .init(
        buffers: Array(value.buffers.dropFirst(before.buffers.count).filter { $0 <= cutoff }),
        levels: Array(value.levels.dropFirst(before.levels.count).filter { $0 <= cutoff }),
        failures: value.failures)
    }
    func satisfied(_ value: Counts.Snapshot) -> Bool {
      (!needsBuffers || value.buffers.count >= 3) && value.levels.count >= 3
    }
    func diagnostic(_ stage: String, _ value: Counts.Snapshot, cutoff: TimeInterval) {
      let raw = counts.values
      let buffers = raw.buffers.dropFirst(before.buffers.count).map { $0 - returned }
      let levels = raw.levels.dropFirst(before.levels.count).map { $0 - returned }
      let firstBuffer = buffers.first.map { String($0) } ?? "none"
      let firstLevel = levels.first.map { String($0) } ?? "none"
      log("\(label) \(stage): elapsed=\(now() - returned)s; cutoff-after-return=\(cutoff - returned)s; buffers=\(value.buffers.count); real-levels=\(value.levels.count); first-buffer-after-return=\(firstBuffer)s; first-level-after-return=\(firstLevel)s; errors=\(value.failures)")
      log("\(label) recorded offsets: buffers=\(buffers); real-levels=\(levels)")
    }
    try await sleep(max(0, checkpointCutoff - now()))
    let checkpoint = samples(through: checkpointCutoff)
    let checkpointPassed = satisfied(checkpoint) && checkpoint.failures.isEmpty
    diagnostic("one-second checkpoint \(checkpointPassed ? "PASS" : "FAIL")", checkpoint, cutoff: checkpointCutoff)
    while now() < finalCutoff, !satisfied(samples(through: finalCutoff)) {
      try await sleep(min(0.1, max(0, finalCutoff - now())))
    }
    let after = samples(through: finalCutoff)
    let result = outcome(checkpointPassed: checkpointPassed, satisfied: satisfied(after),
      hasErrors: !after.failures.isEmpty)
    diagnostic(result, after, cutoff: finalCutoff)
    try requireCapture(satisfied(after) && after.failures.isEmpty,
      "\(label): \(result); required three real levels\(needsBuffers ? " and Recognizer buffers" : "") within 30 seconds after return")
    return result
  }

  @MainActor
  static func observationSelfTests() async throws {
    let cases: [(String, [TimeInterval], [TimeInterval], Bool, String)] = [
      ("delayed observer excludes 1.12s samples", [1.12, 1.13, 1.14], [1.5], true,
        "late-recovery-in-same-process"),
      ("delayed final observer excludes post-bound samples", [30.12, 30.13, 30.14], [1.5, 30.5], true,
        "persistent-stall-at-bound"),
      ("third sample after checkpoint is late", [0.2, 0.3, 1.12], [1.5], true,
        "late-recovery-in-same-process"),
      ("inclusive one-second cutoff", [0.2, 0.3, 1], [1.5], true,
        "within-one-second"),
      ("inclusive final cutoff", [29.8, 29.9, 30], [1.5, 30.5], true,
        "late-recovery-in-same-process"),
      ("startup samples retain negative offsets", [-0.3, -0.2, -0.1], [1.5], true,
        "within-one-second"),
      ("idle resumption excludes late levels", [1.12, 1.13, 1.14], [1.5], false,
        "late-recovery-in-same-process"),
      ("no samples reaches bound", [], [1.5, 30.5], true,
        "persistent-stall-at-bound")
    ]
    var failures: [String] = []
    for (label, offsets, wakes, needsBuffers, expected) in cases {
      let counts = Counts()
      var instant: TimeInterval = 100
      var sequence: UInt64 = 1
      counts.receive(.init(sequence: sequence, generation: 1, isMonitoring: true), at: 99)
      // Old samples cannot satisfy this phase.
      for _ in 0..<3 {
        sequence += 1
        counts.buffer(at: 99)
        counts.receive(.init(sequence: sequence, generation: 1, isMonitoring: true), at: 99)
      }
      var pending = offsets
      func deliver() {
        while let first = pending.first, 100 + first <= instant {
          pending.removeFirst()
          sequence += 1
          if needsBuffers { counts.buffer(at: 100 + first) }
          counts.receive(.init(sequence: sequence, generation: 1, isMonitoring: true), at: 100 + first)
        }
      }
      var wakeIndex = 0
      var actual: String
      do {
        actual = try await observe(label, counts: counts, needsBuffers: needsBuffers,
          now: { instant }, sleep: { _ in
            instant = 100 + wakes[min(wakeIndex, wakes.count - 1)]
            wakeIndex += 1
            deliver()
          }, operation: { deliver() })
      } catch let error as CaptureCheckFailed {
        actual = error.message.contains("persistent-stall-at-bound") ? "persistent-stall-at-bound" : error.message
      }
      if actual != expected { failures.append("\(label): expected \(expected), got \(actual)") }
      log("Self-test \(actual == expected ? "PASS" : "FAIL"): \(label)")
    }
    try requireCapture(failures.isEmpty, failures.joined(separator: "\n"))
    log("Observer self-tests passed: \(cases.count) deterministic cases; no real sleeps or hardware")
  }

  static func main() async throws {
    if CommandLine.arguments.contains("--self-test") {
      precondition(outcome(checkpointPassed: true, satisfied: true, hasErrors: false) == "within-one-second")
      precondition(outcome(checkpointPassed: false, satisfied: true, hasErrors: false) == "late-recovery-in-same-process")
      precondition(outcome(checkpointPassed: false, satisfied: false, hasErrors: false) == "persistent-stall-at-bound")
      precondition(outcome(checkpointPassed: false, satisfied: true, hasErrors: true) == "capture-failed")
      let counts = Counts()
      counts.receive(.init(sequence: 1, generation: 1, isMonitoring: true))
      precondition(counts.values.levels.isEmpty)
      counts.receive(.init(sequence: 2, generation: 1, isMonitoring: true, level: 0))
      precondition(counts.values.levels.count == 1, "silence is real audio")
      try await observationSelfTests()
      log("Probe self-test passed: classification and startup-snapshot exclusion; no hardware capture")
      return
    }
    let snapshot = try CoreAudioInputDevices.snapshot()
    let route = AudioInputRoute(readHardware: { try CoreAudioInputDevices.snapshot() })
    route.update(deviceID: snapshot.defaultDeviceID)
    let systemID = try route.deviceIDForCapture()
    log("Live inventory: \(snapshot.devices.count) input devices; System device: \(String(describing: systemID))")
    for device in snapshot.devices {
      route.update(deviceID: device.deviceID, preferredUID: device.id)
      let resolved = try route.deviceIDForCapture()
      precondition(resolved == device.deviceID)
    }
    route.update(deviceID: systemID, preferredUID: "Talkify-probe-missing-device")
    let fallback = try route.deviceIDForCapture()
    precondition(fallback == systemID)
    route.update(deviceID: systemID)
    log("Verified live UID resolution, System default, and missing-device fallback without modifying OS settings")
    guard CommandLine.arguments.contains("--capture") else { return }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      log("Capture UNVERIFIED: microphone permission is not already authorized; no permission prompt requested")
      return
    }
    guard systemID != nil else {
      log("Capture UNVERIFIED: no effective input")
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--uid") {
      guard index + 1 < CommandLine.arguments.count,
        let selected = snapshot.devices.first(where: { $0.id == CommandLine.arguments[index + 1] }) else {
        throw CaptureCheckFailed(message: "--uid requires an exact available UID; refusing fallback")
      }
      route.update(deviceID: selected.deviceID, preferredUID: selected.id)
      log("Explicit input: \(selected.name) [\(selected.deviceID)]; UID=\(selected.id)")
    }
    let counts = Counts()
    route.setCaptureHandler { counts.receive($0) }
    let monitor = AudioInputLevelMonitor(route: route)
    defer { monitor.stop() }
    try await observe("initial idle meter", counts: counts, needsBuffers: false) { monitor.start() }
    let input = MicrophoneInput(
      feed: { _ in counts.buffer(); return true },
      failureHandler: { error in log("Capture failed: \(error.localizedDescription)") },
      route: route
    )
    defer { input.stop() }
    // Use the integer PCM format requested by Apple Speech on macOS 27.
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
      sampleRate: 16_000, channels: 1, interleaved: false)!
    do {
      try await observe("initial dictation", counts: counts, needsBuffers: true) {
        try input.start(outputFormat: format)
      }
      if CommandLine.arguments.contains("--switch") {
        for device in snapshot.devices { log("Available input: \(device.name) [\(device.deviceID)]") }
        guard let alternate = snapshot.devices.first(where: {
          $0.deviceID != systemID && $0.name.localizedCaseInsensitiveContains("MacBook")
        }) else {
          log("Live switch UNVERIFIED: no alternate built-in input was found")
          return
        }
        // Repeat restoration in one owner; passing a new process cannot erase
        // a failed handoff or prove that a retiring tap's replacement started.
        let phases = (1...3).flatMap { cycle in
          [
            ("cycle \(cycle) explicit input", alternate.id),
            ("cycle \(cycle) missing UID fallback (simulated absence)", "Talkify-probe-missing-device"),
            ("cycle \(cycle) preferred input restored (policy change, not physical reconnect)", alternate.id)
          ]
        }
        for (label, preferred) in phases {
          try await observe(label, counts: counts, needsBuffers: true) {
            let selection = AudioInputSelection(preferredUID: preferred,
              devices: snapshot.devices, defaultDeviceID: snapshot.defaultDeviceID)
            route.update(deviceID: selection.effectiveInput?.deviceID, preferredUID: preferred)
          }
          log("Resolved device: \(String(describing: route.deviceID))")
        }
      }
      try await observe("idle meter resumption", counts: counts, needsBuffers: false) { input.stop() }
      monitor.stop()
    } catch {
      input.stop()
      monitor.stop()
      throw error
    }
    let result = counts.values
    log("Real capture: \(result.buffers.count) Recognizer buffers; \(result.levels.count) real-level snapshots; \(result.failures.count) errors")
    try requireCapture(!result.buffers.isEmpty && !result.levels.isEmpty && result.failures.isEmpty,
      "capture must deliver buffers and levels without errors")
    precondition(!route.isDictationActive)
    log("Verified idle meter → dictation → idle meter handoff; audio was discarded, never saved")
  }
}
