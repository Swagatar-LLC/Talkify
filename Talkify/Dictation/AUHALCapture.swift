import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

typealias AUHALRender = @convention(c) (AudioUnit, UnsafeMutablePointer<AudioUnitRenderActionFlags>?,
  UnsafePointer<AudioTimeStamp>, UInt32, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus

protocol AUHALNativeOperations: Sendable {
  var render: AUHALRender { get }
  func create() throws -> AudioUnit
  func set(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
    _ element: AudioUnitElement, _ data: UnsafeRawPointer, _ size: UInt32) -> OSStatus
  func get(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
    _ element: AudioUnitElement, _ data: UnsafeMutableRawPointer, _ size: inout UInt32) -> OSStatus
  func initialize(_ unit: AudioUnit) -> OSStatus
  func start(_ unit: AudioUnit) -> OSStatus
  func stop(_ unit: AudioUnit) -> OSStatus
  func uninitialize(_ unit: AudioUnit) -> OSStatus
  func dispose(_ unit: AudioUnit) -> OSStatus
}

struct LiveAUHALOperations: AUHALNativeOperations {
  let render: AUHALRender = AudioUnitRender
  func create() throws -> AudioUnit {
    var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else { throw AUHALCapture.Failure.status(-1) }
    var instance: AudioUnit?
    let status = AudioComponentInstanceNew(component, &instance)
    guard status == noErr, let instance else {
      if let instance { _ = AudioComponentInstanceDispose(instance) }
      throw AUHALCapture.Failure.status(status)
    }
    return instance
  }
  func set(_ u: AudioUnit, _ p: AudioUnitPropertyID, _ s: AudioUnitScope,
    _ e: AudioUnitElement, _ d: UnsafeRawPointer, _ n: UInt32) -> OSStatus {
    AudioUnitSetProperty(u, p, s, e, d, n)
  }
  func get(_ u: AudioUnit, _ p: AudioUnitPropertyID, _ s: AudioUnitScope,
    _ e: AudioUnitElement, _ d: UnsafeMutableRawPointer, _ n: inout UInt32) -> OSStatus {
    AudioUnitGetProperty(u, p, s, e, d, &n)
  }
  func initialize(_ u: AudioUnit) -> OSStatus { AudioUnitInitialize(u) }
  func start(_ u: AudioUnit) -> OSStatus { AudioOutputUnitStart(u) }
  func stop(_ u: AudioUnit) -> OSStatus { AudioOutputUnitStop(u) }
  func uninitialize(_ u: AudioUnit) -> OSStatus { AudioUnitUninitialize(u) }
  func dispose(_ u: AudioUnit) -> OSStatus { AudioComponentInstanceDispose(u) }
}

/// One producer (AUHAL IO), one consumer (the microphone queue). A full ring
/// fails capture rather than silently losing words. Neither side reuses frames
/// until the other's release has published ownership.
final class AUHALCapture: @unchecked Sendable {
  enum Failure: Error { case status(OSStatus), render(OSStatus), invalidFormat, overflow }
  let operations: any AUHALNativeOperations
  private(set) var unit: AudioUnit?
  private(set) var format = AudioStreamBasicDescription()
  private(set) var context: AUHALRing?
  private var admission: AUHALAdmission?
  private var initialized = false
  private var started = false
  private var disposalFailed = false

  init(operations: any AUHALNativeOperations = LiveAUHALOperations()) { self.operations = operations }

  func open(device: AudioDeviceID) throws {
    guard unit == nil, !disposalFailed, device != kAudioObjectUnknown else { throw Failure.invalidFormat }
    do {
      let u = try operations.create()
      unit = u
      try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))
      try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0))
      try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device)
      let input: UInt32 = try get(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, 0)
      let output: UInt32 = try get(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, 1)
      let actual: UInt32 = try get(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, 0)
      guard input == 1, output == 0, actual == device else { throw Failure.invalidFormat }
      let hardware = try hardwareFormat()
      guard hardware.mSampleRate.isFinite, hardware.mSampleRate >= 8000, hardware.mSampleRate <= 384000,
        hardware.mChannelsPerFrame > 0, hardware.mChannelsPerFrame <= 8 else { throw Failure.invalidFormat }
      let channels = hardware.mChannelsPerFrame
      format = AudioStreamBasicDescription(mSampleRate: hardware.mSampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: channels * 4,
        mFramesPerPacket: 1, mBytesPerFrame: channels * 4, mChannelsPerFrame: channels,
        mBitsPerChannel: 32, mReserved: 0)
      try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format)
      let actualFormat: AudioStreamBasicDescription = try get(kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output, 1, AudioStreamBasicDescription())
      guard actualFormat.mSampleRate == format.mSampleRate,
        actualFormat.mFormatID == format.mFormatID, actualFormat.mFormatFlags == format.mFormatFlags,
        actualFormat.mChannelsPerFrame == channels, actualFormat.mBytesPerFrame == channels * 4,
        actualFormat.mBitsPerChannel == 32, actualFormat.mFramesPerPacket == 1,
        actualFormat.mBytesPerPacket == channels * 4 else { throw Failure.invalidFormat }
      let maximum: UInt32 = try get(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, 0)
      guard maximum > 0, maximum <= 65536 else { throw Failure.invalidFormat }
      try set(kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, UInt32(0))
      let ring = AUHALRing(unit: u, maximum: maximum, channels: channels, render: operations.render)
      context = ring
      let token = try AUHALAdmission.make(ring)
      admission = token
      try set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, makeAUHALCallback(token))
      initialized = true
      try check(operations.initialize(u))
      started = true
      try check(operations.start(u))
    } catch {
      _ = close()
      throw error
    }
  }

  func hardwareFormat() throws -> AudioStreamBasicDescription {
    try get(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, AudioStreamBasicDescription())
  }

  /// Admission, not native disposal, establishes payload quiescence. Only the
  /// microphone's serial recovery queue may open/close; never the render thread.
  @discardableResult func close() -> Bool {
    guard !disposalFailed else { return false }
    guard let u = unit else { return true }
    if let admission {
      _ = admission.state.bitwiseOr(1, ordering: .acquiringAndReleasing)
      let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
      while admission.state.load(ordering: .acquiring) & 2 != 0 {
        if ContinuousClock.now >= deadline { return poison() }
        Thread.sleep(forTimeInterval: 0.001)
      }
    }
    if started, operations.stop(u) != noErr { return poison() }
    if initialized, operations.uninitialize(u) != noErr { return poison() }
    if operations.dispose(u) != noErr { return poison() }
    unit = nil
    context = nil
    admission = nil
    started = false
    initialized = false
    return true
  }

  private func poison() -> Bool {
    // A timed-out render or failed native teardown owns this storage until
    // process exit. MicrophoneInput propagates false into shared route poison.
    if let context { _ = Unmanaged.passRetained(context) }
    disposalFailed = true
    return false
  }

  private func check(_ status: OSStatus) throws {
    if status != noErr { throw Failure.status(status) }
  }
  private func set<T>(_ p: AudioUnitPropertyID, _ s: AudioUnitScope, _ e: AudioUnitElement, _ value: T) throws {
    var value = value
    try withUnsafeBytes(of: &value) { try check(operations.set(unit!, p, s, e, $0.baseAddress!, UInt32($0.count))) }
  }
  private func get<T>(_ p: AudioUnitPropertyID, _ s: AudioUnitScope, _ e: AudioUnitElement, _ initial: T) throws -> T {
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutableBytes(of: &value) { try check(operations.get(unit!, p, s, e, $0.baseAddress!, &size)) }
    guard size == MemoryLayout<T>.size else { throw Failure.invalidFormat }
    return value
  }
  deinit { _ = close() }
}

final class AUHALRing: @unchecked Sendable {
  let render: AUHALRender
  let unit: AudioUnit
  let maximum: UInt32
  let channels: UInt32
  // Frame-packed storage covers 100ms at the maximum supported 384kHz,
  // independently of callback length, plus one maximum-sized render.
  let capacity: Int
  let scratch: UnsafeMutablePointer<Float>
  let samples: UnsafeMutablePointer<Float>
  let list: UnsafeMutablePointer<AudioBufferList>
  let write = Atomic<UInt64>(0)
  let read = Atomic<UInt64>(0)
  let error = Atomic<Int32>(0)
  let errorKind = Atomic<Int32>(0)
  var failure: AUHALCapture.Failure? {
    switch errorKind.load(ordering: .acquiring) {
    case 1: return .overflow
    case 2: return .invalidFormat
    case 3: return .render(error.load(ordering: .relaxed))
    default: return nil
    }
  }

  init(unit: AudioUnit, maximum: UInt32, channels: UInt32, render: @escaping AUHALRender) {
    self.render = render
    self.unit = unit; self.maximum = maximum; self.channels = channels
    capacity = 38400 + Int(maximum)
    samples = .allocate(capacity: capacity * Int(channels))
    samples.initialize(repeating: 0, count: capacity * Int(channels))
    scratch = .allocate(capacity: Int(maximum * channels))
    scratch.initialize(repeating: 0, count: Int(maximum * channels))
    list = .allocate(capacity: 1)
    list.initialize(to: AudioBufferList(mNumberBuffers: 1,
      mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: 0, mData: nil)))
  }

  func drain(_ consume: (UnsafePointer<Float>, UInt32) throws -> Void) rethrows {
    var r = read.load(ordering: .relaxed)
    let w = write.load(ordering: .acquiring)
    while r < w {
      let offset = Int(r % UInt64(capacity))
      let frames = min(Int(w - r), Int(maximum), capacity - offset)
      try consume(UnsafePointer(samples.advanced(by: offset * Int(channels))), UInt32(frames))
      r += UInt64(frames)
      read.store(r, ordering: .releasing)
    }
  }

  deinit {
    samples.update(repeating: 0, count: capacity * Int(channels))
    scratch.update(repeating: 0, count: Int(maximum * channels))
    samples.deallocate(); scratch.deallocate(); list.deinitialize(count: 1); list.deallocate()
  }
}

/// Never recycled: a dispatched callback may enter after successful disposal.
/// Only these small tokens survive normal retirement, never PCM storage.
final class AUHALAdmission: @unchecked Sendable {
  private static let issued = Mutex<Int>(0)
  static let limit = 65536
  let state = Atomic<UInt32>(0) // CLOSED = 1, BUSY = 2
  let overlaps = Atomic<Bool>(false)
  let payload: UnsafeMutableRawPointer

  private init(_ ring: AUHALRing) { payload = Unmanaged.passUnretained(ring).toOpaque() }

  static func make(_ ring: AUHALRing) throws -> AUHALAdmission {
    try issued.withLock { count in
      guard count < limit else { throw AUHALCapture.Failure.invalidFormat }
      count += 1
      let token = AUHALAdmission(ring)
      _ = Unmanaged.passRetained(token)
      return token
    }
  }
}

nonisolated func makeAUHALCallback(_ token: AUHALAdmission) -> AURenderCallbackStruct {
  AURenderCallbackStruct(inputProc: { refcon, flags, timestamp, _, frames, _ in
    let token = Unmanaged<AUHALAdmission>.fromOpaque(refcon).takeUnretainedValue()
    let entry = token.state.compareExchange(expected: 0, desired: 2, ordering: .acquiringAndReleasing)
    guard entry.exchanged else {
      if entry.original & 2 != 0 { token.overlaps.store(true, ordering: .relaxed) }
      return noErr
    }
    // Release BUSY only after the last payload access. Close preserves CLOSED.
    defer { _ = token.state.bitwiseAnd(~UInt32(2), ordering: .releasing) }
    return renderAUHALPayload(token.payload, flags, timestamp, frames)
  }, inputProcRefCon: Unmanaged.passUnretained(token).toOpaque())
}

// Keep even ARC's final payload release inside the admitted interval.
nonisolated private func renderAUHALPayload(_ payload: UnsafeMutableRawPointer,
  _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
  _ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
  let r = Unmanaged<AUHALRing>.fromOpaque(payload).takeUnretainedValue()
  guard r.errorKind.load(ordering: .relaxed) == 0, frames > 0 else { return noErr }
  let w = r.write.load(ordering: .relaxed)
  guard frames <= r.maximum, w - r.read.load(ordering: .acquiring) + UInt64(frames) <= UInt64(r.capacity) else {
    r.error.store(kAudioUnitErr_TooManyFramesToProcess, ordering: .releasing)
    r.errorKind.store(1, ordering: .releasing)
    return kAudioUnitErr_TooManyFramesToProcess
  }
  let storage = r.scratch
  r.list.pointee.mBuffers = AudioBuffer(mNumberChannels: r.channels,
    mDataByteSize: frames * r.channels * 4, mData: storage)
  let status = r.render(r.unit, flags, timestamp, 1, frames, r.list)
  guard status == noErr else {
    r.error.store(status, ordering: .relaxed)
    r.errorKind.store(3, ordering: .releasing)
    return status
  }
  guard r.list.pointee.mNumberBuffers == 1, r.list.pointee.mBuffers.mData == UnsafeMutableRawPointer(storage),
    r.list.pointee.mBuffers.mNumberChannels == r.channels,
    r.list.pointee.mBuffers.mDataByteSize == frames * r.channels * 4 else {
    r.error.store(kAudio_ParamError, ordering: .relaxed)
    r.errorKind.store(2, ordering: .releasing)
    return kAudio_ParamError
  }
  let offset = Int(w % UInt64(r.capacity))
  let first = min(Int(frames), r.capacity - offset)
  r.samples.advanced(by: offset * Int(r.channels)).update(from: storage, count: first * Int(r.channels))
  if first < Int(frames) {
    r.samples.update(from: storage.advanced(by: first * Int(r.channels)),
      count: (Int(frames) - first) * Int(r.channels))
  }
  r.write.store(w + UInt64(frames), ordering: .releasing)
  return noErr
}
