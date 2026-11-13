import AVFAudio
import Accelerate
import AudioToolbox
import AVFoundation
import Synchronization

final class MicrophoneInput: @unchecked Sendable {
  enum InputError: LocalizedError, Sendable {
    case unavailable
    case permissionDenied
    case noFirstBuffer
    case routingFailed(OSStatus)
    case captureFailed(OSStatus)
    case captureOverflow
    case invalidCaptureFormat
    case converterCreationFailed
    case conversionFailed(String)
    case analyzerBackpressure

    var errorDescription: String? {
      switch self {
      case .unavailable:
        "No microphone input is available."
      case .permissionDenied:
        "Microphone access is denied. Enable it in System Settings."
      case .noFirstBuffer:
        "The microphone started but supplied no audio. Check the microphone or choose another input."
      case let .routingFailed(status):
        "The selected microphone could not be opened (\(status))."
      case let .captureFailed(status):
        "Microphone capture failed (\(status))."
      case .captureOverflow:
        "Microphone capture could not keep up with incoming audio."
      case .invalidCaptureFormat:
        "The microphone supplied an unsupported audio format."
      case .converterCreationFailed:
        "The microphone audio format is unsupported."
      case let .conversionFailed(message):
        "Microphone conversion failed: \(message)"
      case .analyzerBackpressure:
        "Speech analysis could not keep up with microphone input."
      }
    }
  }

  /// A tap can start successfully without ever calling back. Each replacement
  /// owns its deadline, even when capture has no AudioInputRoute.
  struct StartupDeadline {
    private(set) var generation: UInt64 = 0
    private var awaitingBuffer = false

    mutating func begin() -> UInt64 {
      generation += 1
      awaitingBuffer = true
      return generation
    }

    mutating func receive(frameCount: AVAudioFrameCount, generation: UInt64) {
      if self.generation == generation, frameCount > 0 { awaitingBuffer = false }
    }

    mutating func cancel() { awaitingBuffer = false }

    mutating func expire(generation: UInt64) -> Bool {
      guard self.generation == generation, awaitingBuffer else { return false }
      awaitingBuffer = false
      return true
    }
  }

  /// The converter into the analyzer's format, rebuilt whenever the tap
  /// starts delivering a different one.
  ///
  /// The input format is not fixed for the life of a session: a Bluetooth
  /// headset switches from A2DP to its 16 kHz hands-free profile the moment
  /// something opens the microphone, so the first buffers after a route
  /// change arrive in a format the session did not start with. One box per
  /// tap, so the audio thread is the only thread that touches it.
  final class ConverterBox: @unchecked Sendable {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
      self.outputFormat = outputFormat
    }

    func converter(for format: AVAudioFormat) throws -> AVAudioConverter {
      if let converter, inputFormat == format { return converter }
      guard let made = AVAudioConverter(from: format, to: outputFormat) else {
        throw InputError.converterCreationFailed
      }
      converter = made
      inputFormat = format
      return made
    }
  }

  private final class InputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
      self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
      lock.withLock {
        guard !supplied else {
          status.pointee = .noDataNow
          return nil
        }

        supplied = true
        status.pointee = .haveData
        return buffer
      }
    }
  }

  private let recoveryQueue = DispatchQueue(label: "com.tgomareli.Talkify.mic-recovery")
  private let route: AudioInputRoute?
  private let feed: (@Sendable (AVAudioPCMBuffer) -> Bool)?
  private let failureHandler: @Sendable (InputError) -> Void
  private let levelHandler: (@Sendable (Float) -> Void)?
  private let operations: any AUHALNativeOperations
  private let permission: @Sendable () -> Bool
  private let defaultInput: @Sendable () throws -> AudioDeviceID?
  private let startupTimeout: TimeInterval
  private var capture: AUHALCapture?
  private var converterBox: ConverterBox?
  private var outputFormat: AVAudioFormat?
  private var timer: DispatchSourceTimer?
  private var routeObserver: (any NSObjectProtocol)?
  private var running = false
  private var unsafeRetirement = false
  private var captureGeneration: UInt64?
  private var boundDevice: AudioDeviceID?
  private var startupDeadline = StartupDeadline()
  private var firstBufferDeadline = ContinuousClock.now
  private var nextFormatCheck = ContinuousClock.now

  init(
    feed: (@Sendable (AVAudioPCMBuffer) -> Bool)? = nil,
    failureHandler: @escaping @Sendable (InputError) -> Void,
    levelHandler: (@Sendable (Float) -> Void)? = nil,
    route: AudioInputRoute? = nil,
    operations: any AUHALNativeOperations = LiveAUHALOperations(),
    permission: @escaping @Sendable () -> Bool = {
      let status = AVCaptureDevice.authorizationStatus(for: .audio)
      return status != .denied && status != .restricted
    },
    defaultInput: @escaping @Sendable () throws -> AudioDeviceID? = {
      try CoreAudioInputDevices.snapshot().defaultDeviceID
    },
    startupTimeout: TimeInterval = 10
  ) {
    self.feed = feed; self.failureHandler = failureHandler; self.levelHandler = levelHandler
    self.route = route; self.operations = operations; self.permission = permission
    self.defaultInput = defaultInput; self.startupTimeout = startupTimeout
  }

  func start(outputFormat: AVAudioFormat) throws {
    try recoveryQueue.sync {
      guard !unsafeRetirement else { throw InputError.unavailable }
      guard !running else { return }
      if feed != nil { route?.setDictationActive(true) }
      self.outputFormat = outputFormat
      running = true
      do {
        if let route {
          routeObserver = NotificationCenter.default.addObserver(
            forName: AudioInputRoute.didChange, object: route, queue: nil
          ) { [weak self] _ in
            self?.recoveryQueue.async { [weak self] in
              guard let self, route.generation != captureGeneration || route.deviceID != boundDevice else { return }
              rebuildCapture()
            }
          }
        }
        try openCapture()
        let timer = DispatchSource.makeTimerSource(queue: recoveryQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
      } catch {
        retire()
        route?.publish(.failed(error.localizedDescription), generation: captureGeneration)
        if feed != nil, !unsafeRetirement { route?.setDictationActive(false) }
        throw mapped(error)
      }
    }
  }

  private func openCapture() throws {
    // A route may change synchronously inside native startup. Never publish
    // that obsolete unit as ready; bounded retries avoid spinning on churn.
    for _ in 0..<3 {
      try openCaptureAttempt()
      guard let route else { return }
      if route.generation == captureGeneration, route.deviceID == boundDevice { return }
      guard capture?.close() != false else { unsafeRetirement = true; throw InputError.unavailable }
      capture = nil
    }
    throw InputError.unavailable
  }

  private func openCaptureAttempt() throws {
    guard permission() else { throw InputError.permissionDenied }
    captureGeneration = route?.beginCapture()
    let device: AudioDeviceID?
    if let route { device = try route.deviceIDForCapture() }
    else { device = try defaultInput() }
    guard let device else { throw InputError.unavailable }
    _ = startupDeadline.begin()
    guard let outputFormat else { throw InputError.unavailable }
    converterBox = ConverterBox(outputFormat: outputFormat)
    let made = AUHALCapture(operations: operations)
    capture = made
    try made.open(device: device)
    boundDevice = device
    firstBufferDeadline = ContinuousClock.now.advanced(by: .seconds(startupTimeout))
    nextFormatCheck = ContinuousClock.now.advanced(by: .milliseconds(500))
    if route == nil || (route?.generation == captureGeneration && route?.deviceID == device) {
      route?.publish(.started, generation: captureGeneration)
    }
  }

  private func rebuildCapture() {
    guard running else { return }
    guard capture?.close() != false else { fail(.unavailable); return }
    capture = nil
    do { try openCapture() } catch { fail(mapped(error)) }
  }

  /// Runs on the same serial queue as retirement. Conversion and feed delivery
  /// finish before stop returns; a retired generation never reaches a Recognizer.
  private func poll() {
    guard running, let capture, let ring = capture.context else { return }
    if let captureGeneration, route?.generation != captureGeneration { rebuildCapture(); return }
    if let error = ring.failure { fail(mapped(error)); return }
    do {
      let format = capture.format
      try drain(ring, format: format)
      if ContinuousClock.now >= firstBufferDeadline,
        startupDeadline.expire(generation: startupDeadline.generation) { fail(.noFirstBuffer); return }
      if ContinuousClock.now >= nextFormatCheck {
        nextFormatCheck = ContinuousClock.now.advanced(by: .milliseconds(500))
        if route == nil, try defaultInput() != boundDevice {
          rebuildCapture()
          return
        }
        let hardware = try capture.hardwareFormat()
        if hardware.mSampleRate != format.mSampleRate || hardware.mChannelsPerFrame != format.mChannelsPerFrame {
          rebuildCapture()
        }
      }
    } catch { fail(mapped(error)) }
  }

  // An offline harness can drive the real consumer without waiting on timers.
  func processPendingAudio() { recoveryQueue.sync { poll() } }

  private func drain(_ ring: AUHALRing, format: AudioStreamBasicDescription) throws {
    guard let box = converterBox else { throw InputError.unavailable }
    var format = format
    guard let inputFormat = AVAudioFormat(streamDescription: &format) else { throw InputError.unavailable }
    try ring.drain { samples, frames in
      if let captureGeneration, route?.generation != captureGeneration { return }
      guard frames > 0 else { return }
      startupDeadline.receive(frameCount: frames, generation: startupDeadline.generation)
      guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
        let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { throw InputError.unavailable }
      buffer.frameLength = frames
      destination.copyMemory(from: samples, byteCount: Int(frames * format.mBytesPerFrame))
      publishLevel(of: buffer, generation: captureGeneration)
      if let feed {
        let converted = try convert(buffer, using: box)
        if let captureGeneration, route?.generation != captureGeneration { return }
        if converted.frameLength > 0, !feed(converted) { throw InputError.analyzerBackpressure }
      }
    }
  }

  func stop() {
    recoveryQueue.sync {
      guard running else { return }
      // Retain the ring across native disposal, then consume the final render
      // that may have been in flight when stop began.
      if let capture, let ring = capture.context {
        let format = capture.format
        if !capture.close() { unsafeRetirement = true }
        else if let error = ring.failure { fail(mapped(error)); return }
        else if captureGeneration == nil || route?.generation == captureGeneration {
          do { try drain(ring, format: format) }
          catch { fail(mapped(error)); return }
        }
      }
      retire()
      if unsafeRetirement {
        route?.publish(.failed(InputError.unavailable.localizedDescription), generation: captureGeneration)
        failureHandler(.unavailable)
      } else {
        route?.publish(.stopped, generation: captureGeneration)
        if feed != nil { route?.setDictationActive(false) }
      }
    }
  }

  private func retire() {
    running = false
    startupDeadline.cancel()
    timer?.cancel(); timer = nil
    if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    routeObserver = nil
    if capture?.close() == false { unsafeRetirement = true }
    // A failed native barrier poisons the shared route until app restart;
    // another owner must not open over a possibly live orphaned unit.
    if unsafeRetirement { route?.invalidate() }
    capture = nil
    converterBox = nil
  }

  private func fail(_ error: InputError) {
    guard running else { return }
    retire()
    route?.publish(.failed(error.localizedDescription), generation: captureGeneration)
    if feed != nil, !unsafeRetirement { route?.setDictationActive(false) }
    failureHandler(error)
  }

  private func mapped(_ error: any Error) -> InputError {
    if let error = error as? InputError { return error }
    if case let AUHALCapture.Failure.status(status) = error { return .routingFailed(status) }
    if case let AUHALCapture.Failure.render(status) = error { return .captureFailed(status) }
    if case AUHALCapture.Failure.invalidFormat = error { return .invalidCaptureFormat }
    if case AUHALCapture.Failure.overflow = error { return .captureOverflow }
    return .unavailable
  }

  deinit {
    timer?.cancel()
    if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    if capture?.close() == false { unsafeRetirement = true }
    if feed != nil, running, !unsafeRetirement { route?.setDictationActive(false) }
    if unsafeRetirement { route?.invalidate() }
  }

  static func hasUsableHardwareInput(_ format: AVAudioFormat) -> Bool {
    format.channelCount > 0 && format.sampleRate > 0
  }

  private func convert(
    _ inputBuffer: AVAudioPCMBuffer,
    using converterBox: ConverterBox
  ) throws -> AVAudioPCMBuffer {
    let ratio = converterBox.outputFormat.sampleRate / inputBuffer.format.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 1

    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: converterBox.outputFormat,
      frameCapacity: capacity
    ) else {
      throw InputError.conversionFailed("Unable to allocate an audio buffer.")
    }

    let converter = try converterBox.converter(for: inputBuffer.format)
    let inputProvider = InputProvider(buffer: inputBuffer)
    var conversionError: NSError?
    let status = converter.convert(
      to: outputBuffer,
      error: &conversionError
    ) { _, inputStatus in
      inputProvider.next(status: inputStatus)
    }

    if let conversionError {
      throw InputError.conversionFailed(conversionError.localizedDescription)
    }

    guard status == .haveData || status == .inputRanDry else {
      throw InputError.conversionFailed("Unexpected converter status \(status.rawValue).")
    }

    return outputBuffer
  }

  /// RMS across the interleaved channels, computed on the consumer queue,
  /// mapped to 0–1 over a 50 dB window: a quiet room sits near zero and
  /// speech fills most of the range.
  private func publishLevel(of buffer: AVAudioPCMBuffer, generation: UInt64?) {
    guard levelHandler != nil || route != nil,
       let samples = buffer.floatChannelData?[0],
       buffer.frameLength > 0
    else { return }

    let rms = vDSP.rootMeanSquare(
      UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength * buffer.format.channelCount))
    )
    let db = 20 * log10(max(rms, .leastNormalMagnitude))
    let level = min(1, max(0, (db + 50) / 50))
    levelHandler?(level)
    route?.publish(.level(level), generation: generation)
  }

}
