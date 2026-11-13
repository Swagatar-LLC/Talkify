import AudioToolbox
import AVFAudio
import Foundation
import Synchronization

final class FakeAUHAL: AUHALNativeOperations, @unchecked Sendable {
  let lock = NSRecursiveLock()
  var events: [String] = []
  var failure: String?
  var mismatch = false
  var rate = 48000.0
  var channels: UInt32 = 1
  var callback = AURenderCallbackStruct()
  var client = AudioStreamBasicDescription()
  var device: UInt32 = 0
  var values: [String: UInt32] = [:]
  var creations = 0
  var emitOnStart = 0
  var onStart: (@Sendable () -> Void)?
  var onStop: (@Sendable () -> Void)?
  var render: AUHALRender = { _, _, _, bus, frames, list in
    guard bus == 1, let data = list.pointee.mBuffers.mData else { return -1 }
    let count = Int(frames * list.pointee.mBuffers.mNumberChannels)
    data.assumingMemoryBound(to: Float.self).update(repeating: 0.25, count: count)
    return noErr
  }
  func record(_ event: String) -> OSStatus {
    events.append(event)
    return failure == event ? -777 : noErr
  }
  func create() throws -> AudioUnit {
    try lock.withLock {
      guard record("create") == 0 else { throw AUHALCapture.Failure.status(-777) }
      creations += 1
      return AudioUnit(bitPattern: creations)!
    }
  }
  func set(_ u: AudioUnit, _ p: AudioUnitPropertyID, _ s: AudioUnitScope,
    _ e: AudioUnitElement, _ d: UnsafeRawPointer, _ n: UInt32) -> OSStatus {
    lock.withLock {
      let key = "\(p):\(s):\(e)"
      let result = record("set:" + key)
      if p == kAudioOutputUnitProperty_SetInputCallback { callback = d.load(as: AURenderCallbackStruct.self) }
      else if p == kAudioUnitProperty_StreamFormat { client = d.load(as: AudioStreamBasicDescription.self) }
      else { values[key] = d.load(as: UInt32.self) }
      if p == kAudioOutputUnitProperty_CurrentDevice { device = d.load(as: UInt32.self) }
      return result
    }
  }
  func get(_ u: AudioUnit, _ p: AudioUnitPropertyID, _ s: AudioUnitScope,
    _ e: AudioUnitElement, _ d: UnsafeMutableRawPointer, _ n: inout UInt32) -> OSStatus {
    lock.withLock {
      let key = "\(p):\(s):\(e)"
      let result = record("get:" + key)
      if p == kAudioUnitProperty_StreamFormat {
        var value = client
        if s == kAudioUnitScope_Input { value.mSampleRate = rate; value.mChannelsPerFrame = channels }
        d.storeBytes(of: value, as: AudioStreamBasicDescription.self)
      } else {
        var value = values[key] ?? 0
        if p == kAudioUnitProperty_MaximumFramesPerSlice { value = 1024 }
        if mismatch && p == kAudioOutputUnitProperty_CurrentDevice { value += 1 }
        d.storeBytes(of: value, as: UInt32.self)
      }
      return result
    }
  }
  func initialize(_ u: AudioUnit) -> OSStatus { lock.withLock { record("initialize") } }
  func start(_ u: AudioUnit) -> OSStatus {
    lock.withLock {
      let count = emitOnStart; emitOnStart = 0
      for _ in 0..<count { _ = emit() }
      let hook = onStart; onStart = nil; hook?()
      return record("start")
    }
  }
  func stop(_ u: AudioUnit) -> OSStatus {
    onStop?()
    return lock.withLock {
      return record("stop")
    }
  }
  func uninitialize(_ u: AudioUnit) -> OSStatus { lock.withLock { record("uninitialize") } }
  func dispose(_ u: AudioUnit) -> OSStatus { lock.withLock { record("dispose") } }
  func emit(_ frames: UInt32 = 1024) -> OSStatus {
    lock.withLock {
      var flags: AudioUnitRenderActionFlags = []
      var time = AudioTimeStamp()
      return callback.inputProc!(callback.inputProcRefCon!, &flags, &time, 1, frames, nil)
    }
  }
}

final class RenderGate: @unchecked Sendable {
  static let shared = RenderGate()
  let calls = Atomic<Int>(0)
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
}

final class ErrorResults: @unchecked Sendable {
  let lock = NSLock()
  var errors: [MicrophoneInput.InputError] = []
  func append(_ error: MicrophoneInput.InputError) { lock.withLock { errors.append(error) } }
}

final class Results: @unchecked Sendable {
  let lock = NSLock()
  var frames = 0
  var failures = 0
  func receive(_ buffer: AVAudioPCMBuffer) -> Bool {
    lock.withLock { frames += Int(buffer.frameLength) }
    return true
  }
  func failed() { lock.withLock { failures += 1 } }
}

@main struct AudioCaptureHarness {
  static func require(_ value: @autoclosure () -> Bool, _ name: String) {
    if !value() { print("FAIL: \(name)"); exit(1) }
    print("PASS: \(name)")
  }
  static func requireSilent(_ value: Bool) {
    if !value { print("FAIL: sustained packed callback delivery"); exit(1) }
  }
  static func main() throws {
    let allowed: Set<String> = ["--admission-timeout-regression", "--admission-seriality-regression",
      "--lifetime-regression", "--startup-route-regression", "--small-callback-regression",
      "--typed-error-regression", "--concurrent-stop-regression", "--token-cap-regression", "--route-timeout-regression", "--failure-retirement-regression", "--offline"]
    guard CommandLine.arguments.count == 2, allowed.contains(CommandLine.arguments[1]) else {
      print("An exact offline harness mode is required.")
      exit(64)
    }
    if CommandLine.arguments.contains("--failure-retirement-regression") {
      for stage in ["stop", "uninitialize", "dispose"] {
        let native = FakeAUHAL(); native.failure = stage
        let capture = AUHALCapture(operations: native)
        try capture.open(device: 42)
        require(!capture.close(), "\(stage) error must poison even if a later dispose could succeed")
        require(capture.context != nil && capture.unit != nil, "\(stage) error retains payload and unit")
        let last = native.events.count
        require(!capture.close() && native.events.count == last, "\(stage) poison cannot retry native teardown")
        require(native.emit(1) == noErr, "\(stage) poison rejects callback without payload access")
      }
      return
    }
    if CommandLine.arguments.contains("--route-timeout-regression") {
      let route = AudioInputRoute(); route.update(deviceID: 42)
      let native = FakeAUHAL(); let results = Results()
      native.render = { _, _, _, _, _, _ in
        RenderGate.shared.entered.signal(); RenderGate.shared.release.wait(); return noErr
      }
      let input = MicrophoneInput(feed: { results.receive($0) }, failureHandler: { _ in results.failed() },
        route: route, operations: native, permission: { true })
      let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
      try input.start(outputFormat: format)
      DispatchQueue.global().async {
        var flags: AudioUnitRenderActionFlags = []; var time = AudioTimeStamp()
        _ = native.callback.inputProc!(native.callback.inputProcRefCon!, &flags, &time, 1, 1, nil)
        RenderGate.shared.finished.signal()
      }
      require(RenderGate.shared.entered.wait(timeout: .now() + 2) == .success, "shared capture admits blocked render")
      input.stop(); input.stop()
      require(results.lock.withLock { results.failures == 1 }, "timeout reports one failure through production owner")
      require(route.deviceID == nil, "timeout poisons shared route")
      let successor = FakeAUHAL()
      let sibling = MicrophoneInput(failureHandler: { _ in }, route: route, operations: successor, permission: { true })
      do { try sibling.start(outputFormat: format); require(false, "poison rejects sibling") } catch {}
      require(successor.creations == 0, "timeout prevents sibling native creation")
      do { try input.start(outputFormat: format); require(false, "poison rejects same owner") } catch {}
      require(native.creations == 1 && !native.events.contains("dispose"), "timed-out owner retains unit and refuses restart")
      RenderGate.shared.release.signal()
      require(RenderGate.shared.finished.wait(timeout: .now() + 2) == .success, "callback safely leaves orphaned retained payload")
      return
    }
    if CommandLine.arguments.contains("--token-cap-regression") {
      let native = FakeAUHAL(); let capture = AUHALCapture(operations: native)
      try capture.open(device: 42)
      let ring = capture.context!
      for _ in 1..<AUHALAdmission.limit { _ = try AUHALAdmission.make(ring) }
      require(capture.close(), "token-cap test retires real production payload")
      do { try capture.open(device: 42); require(false, "token cap must reject open") } catch {}
      require(capture.context == nil, "token cap cannot accumulate PCM storage")
      require(native.events.last == "dispose", "token cap tears down unstarted native allocation")
      require(native.events.filter { $0 == "start" }.count == 1, "token cap refuses native start")
      return
    }
    if CommandLine.arguments.contains("--lifetime-regression") {
      let native = FakeAUHAL()
      let capture = AUHALCapture(operations: native)
      try capture.open(device: 42)
      weak let retired = capture.context
      let oldCallback = native.callback
      require(capture.close(), "dispose succeeds without relying on a native join")
      require(retired == nil, "normal retirement reclaims PCM payload")
      var flags: AudioUnitRenderActionFlags = []; var time = AudioTimeStamp()
      for _ in 0..<1000 {
        requireSilent(oldCallback.inputProc!(oldCallback.inputProcRefCon!, &flags, &time, 1, 1, nil) == noErr)
      }
      require(capture.close(), "repeated stop is idempotent")
      try capture.open(device: 42)
      require(oldCallback.inputProcRefCon != native.callback.inputProcRefCon, "restart never reuses callback token address")
      _ = oldCallback.inputProc!(oldCallback.inputProcRefCon!, &flags, &time, 1, 1, nil)
      require(capture.context!.write.load(ordering: .acquiring) == 0, "old callback cannot publish into restarted session")
      require(native.emit(1) == 0, "new session remains usable")
      require(capture.close(), "restarted capture retires")
      for stage in ["initialize", "start", "set:\(kAudioOutputUnitProperty_SetInputCallback):0:0"] {
        let failed = FakeAUHAL(); failed.failure = stage
        let partial = AUHALCapture(operations: failed)
        do { try partial.open(device: 42); require(false, "failure must throw") } catch {}
        require(partial.context == nil, "failed startup reclaims PCM after quiescence")
        require(failed.emit(1) == noErr, "callback after failed startup rejects through permanent token")
        require(partial.close(), "failure cleanup remains idempotent")
      }
      for stage in ["stop", "uninitialize", "dispose"] {
        let failed = FakeAUHAL(); failed.failure = stage
        let partial = AUHALCapture(operations: failed)
        try partial.open(device: 42)
        require(!partial.close(), "native \(stage) error poisons retirement")
        require(partial.context != nil && !partial.close(), "native failure retains payload and refuses retries")
        require(failed.emit(1) == noErr, "poisoned token rejects late callback")
        let count = failed.creations
        do { try partial.open(device: 42); require(false, "poison refuses restart") } catch {}
        require(failed.creations == count, "poison cannot create replacement")
      }
      return
    }
    if CommandLine.arguments.contains("--admission-seriality-regression") {
      let native = FakeAUHAL()
      native.render = { _, _, _, _, _, _ in
        let previous = RenderGate.shared.calls.wrappingAdd(1, ordering: .relaxed).oldValue
        if previous == 0 {
          RenderGate.shared.entered.signal()
          RenderGate.shared.release.wait()
        }
        return noErr
      }
      let capture = AUHALCapture(operations: native)
      try capture.open(device: 42)
      DispatchQueue.global().async {
        var flags: AudioUnitRenderActionFlags = []; var time = AudioTimeStamp()
        _ = native.callback.inputProc!(native.callback.inputProcRefCon!, &flags, &time, 1, 1, nil)
        RenderGate.shared.finished.signal()
      }
      require(RenderGate.shared.entered.wait(timeout: .now() + 2) == .success, "first producer admitted")
      _ = native.emit(1)
      require(RenderGate.shared.calls.load(ordering: .relaxed) == 1, "overlapping callback cannot access producer payload")
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { RenderGate.shared.release.signal() }
      require(capture.close(), "close waits for admitted producer before teardown")
      require(RenderGate.shared.finished.wait(timeout: .now() + 2) == .success, "admitted producer completed")
      require(native.emit(1) == noErr, "late callback rejected after successful disposal")
      require(RenderGate.shared.calls.load(ordering: .relaxed) == 1, "late entry never renders")
      return
    }
    if CommandLine.arguments.contains("--admission-timeout-regression") {
      let native = FakeAUHAL()
      native.render = { _, _, _, _, _, _ in
        RenderGate.shared.entered.signal()
        RenderGate.shared.release.wait()
        return noErr
      }
      let capture = AUHALCapture(operations: native)
      try capture.open(device: 42)
      let heldRing = capture.context!
      DispatchQueue.global().async {
        var flags: AudioUnitRenderActionFlags = []; var timestamp = AudioTimeStamp()
        _ = native.callback.inputProc!(native.callback.inputProcRefCon!, &flags, &timestamp, 1, 1024, nil)
        RenderGate.shared.finished.signal()
      }
      require(RenderGate.shared.entered.wait(timeout: .now() + 2) == .success, "render admitted before close")
      let began = ContinuousClock.now
      let retired = capture.close()
      require(!retired, "blocked admitted render poisons retirement rather than disposing")
      require(began.duration(to: .now) < .seconds(2), "retirement wait is bounded")
      require(!native.events.contains("dispose") && !native.events.contains("uninitialize") && !native.events.contains("stop"), "timeout preserves resources used by render")
      require(!capture.close(), "poisoned retirement is idempotent")
      RenderGate.shared.release.signal()
      require(RenderGate.shared.finished.wait(timeout: .now() + 2) == .success, "retained payload supports callback exit after timeout")
      withExtendedLifetime(heldRing) {}
      return
    }
    if CommandLine.arguments.contains("--concurrent-stop-regression") {
      let native = FakeAUHAL()
      native.render = { _, _, _, _, frames, list in
        RenderGate.shared.entered.signal()
        RenderGate.shared.release.wait()
        list.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.25, count: Int(frames))
        return noErr
      }
      let results = Results()
      let input = MicrophoneInput(feed: { results.receive($0) }, failureHandler: { _ in results.failed() },
        operations: native, permission: { true }, defaultInput: { 42 })
      try input.start(outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!)
      // Unlike emit(), this invokes the C callback without the fake's lock.
      DispatchQueue.global().async {
        var flags: AudioUnitRenderActionFlags = []; var timestamp = AudioTimeStamp()
        _ = native.callback.inputProc!(native.callback.inputProcRefCon!, &flags, &timestamp, 1, 1024, nil)
        RenderGate.shared.finished.signal()
      }
      require(RenderGate.shared.entered.wait(timeout: .now() + 2) == .success, "callback is genuinely in flight")
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
        RenderGate.shared.release.signal()
      }
      input.stop()
      require(results.lock.withLock { results.frames == 1024 && results.failures == 0 }, "concurrent final render survives retirement and is drained once")
      return
    }
    if CommandLine.arguments.contains("--startup-route-regression") {
      let native = FakeAUHAL()
      let route = AudioInputRoute(); route.update(deviceID: 11)
      native.onStart = {
        route.update(deviceID: 12)
        native.emitOnStart = 1
      }
      let result = Results()
      let input = MicrophoneInput(feed: { result.receive($0) }, failureHandler: { _ in result.failed() },
        route: route, operations: native, permission: { true })
      try input.start(outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!)
      input.processPendingAudio()
      require(native.lock.withLock { native.device == 12 && native.creations == 2 }, "route changed inside native start opens only one replacement")
      input.stop()
      require(result.lock.withLock { result.frames == 1024 && result.failures == 0 }, "replacement startup samples survive queued stale notifications")
      return
    }
    if CommandLine.arguments.contains("--typed-error-regression") {
      for mode in ["render", "format", "overflow"] {
        let native = FakeAUHAL()
        if mode == "render" { native.render = { _, _, _, _, _, _ in -555 } }
        if mode == "format" { native.render = { _, _, _, _, _, list in list.pointee.mNumberBuffers = 0; return noErr } }
        let errors = ErrorResults()
        let input = MicrophoneInput(failureHandler: { errors.append($0) }, operations: native,
          permission: { true }, defaultInput: { 42 })
        try input.start(outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!)
        _ = native.emit(mode == "overflow" ? 1025 : 1024)
        input.processPendingAudio(); input.stop()
        require(errors.lock.withLock {
          guard errors.errors.count == 1 else { return false }
          switch (mode, errors.errors[0]) {
          case ("render", .captureFailed(-555)), ("format", .invalidCaptureFormat), ("overflow", .captureOverflow): return true
          default: return false
          }
        }, "\(mode) failure retains microphone diagnosis, not analyzer backpressure")
      }
      return
    }
    if CommandLine.arguments.contains("--small-callback-regression") {
      let native = FakeAUHAL(); native.rate = 384000; native.channels = 8
      let capture = AUHALCapture(operations: native)
      try capture.open(device: 42)
      var accepted = 0
      for _ in 0..<38400 {
        if native.emit(1) != 0 { break }
        accepted += 1
      }
      require(accepted == 38400, "100ms at 384kHz with one-frame callbacks accepted (actual \(accepted))")
      var delivered = 0
      capture.context!.drain { samples, frames in
        delivered += Int(frames)
        require(samples[0] == 0.25, "packed stream preserves samples")
      }
      require(delivered == 38400, "packed stream delivers every frame")
      var total = 0
      for _ in 0..<100 {
        for _ in 0..<3840 { requireSilent(native.emit(1) == 0) }
        capture.context!.drain { samples, frames in
          for index in 0..<Int(frames * 8) { requireSilent(samples[index] == 0.25) }
          total += Int(frames)
        }
      }
      require(total == 384000, "one second of 10ms consumer cadence preserves all eight channels across wraparound")
      _ = capture.close()
      return
    }
    let fake = FakeAUHAL()
    let capture = AUHALCapture(operations: fake)
    try capture.open(device: 42)
    require(fake.device == 42, "binds effective device")
    let readback = fake.events.firstIndex(of: "get:\(kAudioOutputUnitProperty_CurrentDevice):0:0")!
    require(readback < fake.events.firstIndex(of: "initialize")!, "device readback precedes initialize")
    require(fake.values["\(kAudioOutputUnitProperty_EnableIO):1:1"] == 1,
      "input scope input element 1 enabled")
    require(fake.values["\(kAudioOutputUnitProperty_EnableIO):2:0"] == 0,
      "output scope output element 0 disabled")
    require(fake.emit() == 0, "real callback renders through injected native operation")
    var received = 0
    capture.context!.drain { samples, frames in
      received += Int(frames)
      require(samples[0] == 0.25, "callback samples survive bounded handoff")
    }
    require(received == 1024, "real ring delivers rendered frames")
    require(capture.close(), "successful capture cleanup")
    require(Array(fake.events.suffix(3)) == ["stop", "uninitialize", "dispose"], "cleanup order")
    let eventCount = fake.events.count
    require(capture.close() && fake.events.count == eventCount, "cleanup idempotent")

    for stage in ["initialize", "start"] {
      let f = FakeAUHAL(); f.failure = stage
      let c = AUHALCapture(operations: f)
      do { try c.open(device: 42); require(false, "rejects failed \(stage)") } catch {}
      require(f.events.last == "dispose", "failed \(stage) disposes")
      require(f.events.contains("uninitialize"), "partial \(stage) uninitializes")
      if stage == "start" { require(f.events.contains("stop"), "partial start stops") }
    }
    let wrong = FakeAUHAL(); wrong.mismatch = true
    do { try AUHALCapture(operations: wrong).open(device: 42); require(false, "wrong device rejected") } catch {}
    require(!wrong.events.contains("initialize"), "readback mismatch refuses initialization")

    let bounded = FakeAUHAL(); let boundedCapture = AUHALCapture(operations: bounded)
    try boundedCapture.open(device: 42)
    let blocks = boundedCapture.context!.capacity / 1024
    for _ in 0..<blocks { require(bounded.emit() == 0, "bounded block accepted") }
    require(bounded.emit() != 0, "full ring fails rather than overwrite")
    require(boundedCapture.context!.write.load(ordering: .acquiring) == UInt64(blocks * 1024), "overflow preserves published frames")
    _ = boundedCapture.close()

    let output = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let shared = FakeAUHAL(); let result = Results()
    let input = MicrophoneInput(feed: { result.receive($0) }, failureHandler: { _ in result.failed() },
      operations: shared, permission: { true }, defaultInput: { 99 })
    try input.start(outputFormat: output)
    require(shared.device == 99, "nil route binds explicit default input")
    _ = shared.emit()
    input.processPendingAudio()
    require(result.lock.withLock { result.frames > 0 }, "shared microphone converts and feeds off callback")
    input.stop(); input.stop()
    require(result.lock.withLock { result.failures == 0 }, "normal shared stop does not report failure")

    let silent = FakeAUHAL(); let deadline = Results()
    let silentInput = MicrophoneInput(failureHandler: { _ in deadline.failed() }, operations: silent,
      permission: { true }, defaultInput: { 99 }, startupTimeout: 0)
    try silentInput.start(outputFormat: output)
    silentInput.processPendingAudio(); silentInput.processPendingAudio()
    require(deadline.lock.withLock { deadline.failures == 1 }, "no first buffer fails once and disposes")
    require(silent.events.last == "dispose", "deadline retires native capture")

    let absent = FakeAUHAL()
    let absentInput = MicrophoneInput(failureHandler: { _ in }, route: AudioInputRoute(), operations: absent,
      permission: { true }, defaultInput: { fatalError("route must not fallback independently") })
    do { try absentInput.start(outputFormat: output); require(false, "absent route rejects capture") } catch {}
    require(absent.creations == 0, "absent effective route never creates native unit")
    let stuck = FakeAUHAL(); stuck.failure = "dispose"
    let stuckInput = MicrophoneInput(failureHandler: { _ in }, operations: stuck,
      permission: { true }, defaultInput: { 99 })
    try stuckInput.start(outputFormat: output)
    stuckInput.stop()
    do { try stuckInput.start(outputFormat: output) } catch {}
    require(stuck.creations == 1, "failed native disposal forbids replacement capture")
    let final = FakeAUHAL()
    let finalResult = Results()
    let finalInput = MicrophoneInput(feed: { finalResult.receive($0) }, failureHandler: { _ in },
      operations: final, permission: { true }, defaultInput: { 99 })
    try finalInput.start(outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!)
    _ = final.emit()
    finalInput.stop()
    require(finalResult.lock.withLock { finalResult.frames == 1024 }, "stop drains already published buffer once")
    let changing = FakeAUHAL(); changing.emitOnStart = 2
    let changingRoute = AudioInputRoute(); changingRoute.update(deviceID: 11)
    let changingResult = Results()
    let changingInput = MicrophoneInput(feed: { buffer in
      _ = changingResult.receive(buffer)
      changingRoute.update(deviceID: 12)
      return true
    }, failureHandler: { _ in }, route: changingRoute, operations: changing, permission: { true })
    try changingInput.start(outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!)
    changingInput.processPendingAudio()
    require(changingResult.lock.withLock { changingResult.frames == 1024 }, "route retirement discards remaining old-generation buffers")
    changingInput.stop()
    let system = FakeAUHAL(); system.device = 99
    let systemInput = MicrophoneInput(failureHandler: { _ in }, operations: system, permission: { true },
      defaultInput: { system.lock.withLock { system.device } })
    try systemInput.start(outputFormat: output)
    system.lock.withLock { system.device = 100 }
    Thread.sleep(forTimeInterval: 0.6)
    systemInput.processPendingAudio()
    require(system.lock.withLock { system.creations == 2 }, "nil route rebuilds when system default input changes")
    systemInput.stop()
    let unsafeRoute = AudioInputRoute(); unsafeRoute.update(deviceID: 42)
    let unsafeNative = FakeAUHAL(); unsafeNative.failure = "dispose"
    let unsafeMeter = MicrophoneInput(failureHandler: { _ in }, route: unsafeRoute,
      operations: unsafeNative, permission: { true })
    try unsafeMeter.start(outputFormat: output)
    unsafeMeter.stop()
    let successor = FakeAUHAL()
    let successorInput = MicrophoneInput(failureHandler: { _ in }, route: unsafeRoute,
      operations: successor, permission: { true })
    do { try successorInput.start(outputFormat: output) } catch {}
    successorInput.stop()
    require(successor.creations == 0, "failed meter disposal blocks sibling dictation capture on shared route")
    let formatNative = FakeAUHAL()
    let formatInput = MicrophoneInput(failureHandler: { _ in }, operations: formatNative,
      permission: { true }, defaultInput: { 99 })
    try formatInput.start(outputFormat: output)
    formatNative.lock.withLock { formatNative.rate = 16000; formatNative.channels = 2 }
    Thread.sleep(forTimeInterval: 0.6)
    formatInput.processPendingAudio()
    require(formatNative.lock.withLock { formatNative.creations == 2 && formatNative.client.mSampleRate == 16000
      && formatNative.client.mChannelsPerFrame == 2 }, "hardware rate and channel changes rebuild negotiated capture")
    let rebuildEvents = formatNative.lock.withLock { formatNative.events }
    let secondCreate = rebuildEvents.lastIndex(of: "create")!
    require(rebuildEvents[..<secondCreate].last == "dispose", "format rebuild disposes old unit before creating replacement")
    formatInput.stop()

    let handoffRoute = AudioInputRoute(); handoffRoute.update(deviceID: 42)
    let meterNative = FakeAUHAL()
    let monitor = AudioInputLevelMonitor(route: handoffRoute, makeCapture: { route, failure in
      MicrophoneInput(failureHandler: failure, route: route, operations: meterNative, permission: { true })
    })
    monitor.start()
    Thread.sleep(forTimeInterval: 0.05)
    let dictationNative = FakeAUHAL()
    let dictation = MicrophoneInput(feed: { _ in true }, failureHandler: { _ in }, route: handoffRoute,
      operations: dictationNative, permission: { true })
    try dictation.start(outputFormat: output)
    require(meterNative.lock.withLock { meterNative.events.last == "dispose" }, "real monitor releases native capture before dictation lease opens")
    monitor.stop()
    dictation.stop()
    Thread.sleep(forTimeInterval: 0.05)
    require(meterNative.lock.withLock { meterNative.creations == 1 }, "hidden Settings meter does not resume idle capture")
    for operation in fake.events.filter({ $0.hasPrefix("set:") || $0.hasPrefix("get:") }) {
      let failing = FakeAUHAL(); failing.failure = operation
      do { try AUHALCapture(operations: failing).open(device: 42); require(false, "property failure propagated") } catch {}
      require(failing.events.last == "dispose", "property failure retires native handle: \(operation)")
    }
    for rate in [0.0, Double.nan, 400000.0] {
      let invalid = FakeAUHAL(); invalid.rate = rate
      do { try AUHALCapture(operations: invalid).open(device: 42); require(false, "invalid format rejected") } catch {}
      require(!invalid.events.contains("start"), "invalid hardware rate cannot start")
    }
    let backpressure = FakeAUHAL(); backpressure.emitOnStart = 1
    let rejected = Results()
    let rejectedInput = MicrophoneInput(feed: { _ in false }, failureHandler: { _ in rejected.failed() },
      operations: backpressure, permission: { true }, defaultInput: { 99 })
    try rejectedInput.start(outputFormat: output)
    rejectedInput.processPendingAudio(); rejectedInput.processPendingAudio()
    require(rejected.lock.withLock { rejected.failures == 1 }, "feed rejection fails once and retires capture")
    require(backpressure.lock.withLock { backpressure.events.last == "dispose" }, "feed rejection disposes native unit")
    let renderFailure = FakeAUHAL(); renderFailure.render = { _, _, _, _, _, _ in -555 }
    let renderCapture = AUHALCapture(operations: renderFailure)
    try renderCapture.open(device: 42)
    require(renderFailure.emit() == -555, "native render failure propagates")
    require(renderCapture.context!.write.load(ordering: .acquiring) == 0, "failed render never publishes samples")
    _ = renderCapture.close()
    let oversized = FakeAUHAL(); let oversizedCapture = AUHALCapture(operations: oversized)
    try oversizedCapture.open(device: 42)
    require(oversized.emit(1025) == kAudioUnitErr_TooManyFramesToProcess, "oversized callback rejected before render")
    _ = oversizedCapture.close()
    let finalFailure = FakeAUHAL(); finalFailure.render = { _, _, _, _, _, _ in -555 }
    let finalError = Results()
    let finalFailureInput = MicrophoneInput(failureHandler: { _ in finalError.failed() },
      operations: finalFailure, permission: { true }, defaultInput: { 99 })
    try finalFailureInput.start(outputFormat: output)
    _ = finalFailure.emit()
    finalFailureInput.stop()
    require(finalError.lock.withLock { finalError.failures == 1 }, "render failure observed by stop is not reported as success")
    print("All offline capture checks passed; no live audio API executed.")
  }
}
