import AVFAudio
import Accelerate
import AudioToolbox
import AVFoundation
import os

final class MicrophoneInput: @unchecked Sendable {
  enum InputError: LocalizedError, Sendable {
    case unavailable
    case permissionDenied
    case noFirstBuffer
    case routingFailed(OSStatus)
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

  /// Replaced rather than restarted when the audio route changes: the old
  /// engine's input chain cannot re-initialise across a Bluetooth profile
  /// switch, which fails with -10868.
  private var audioEngine = AVAudioEngine()
  /// Serialises route recovery off the notification thread.
  private let recoveryQueue = DispatchQueue(label: "com.tgomareli.Talkify.mic-recovery")
  private var configurationObserver: (any NSObjectProtocol)?
  private var routeObserver: (any NSObjectProtocol)?
  private let route: AudioInputRoute?
  private var analyzerFormat: AVAudioFormat?
  private var recovering = false
  /// A route change that arrived while recovering. Dropping it would leave a
  /// dead engine behind, and a headset settling its profile can post more
  /// than one.
  private var recoveryPending = false
  /// Nil for level-only capture; otherwise feeds whichever Recognizer is active.
  private let feed: (@Sendable (AVAudioPCMBuffer) -> Bool)?
  private let failureHandler: @Sendable (InputError) -> Void
  /// Normalized microphone level (0–1) per tap buffer, for the HUD's
  /// voice-reactive visual. Called on the audio thread.
  private let levelHandler: (@Sendable (Float) -> Void)?
  private let stateLock = NSLock()

  private var running = false
  private var reportedFailure = false
  private var captureGeneration: UInt64?
  private var startupDeadline = StartupDeadline()

  init(
    feed: (@Sendable (AVAudioPCMBuffer) -> Bool)? = nil,
    failureHandler: @escaping @Sendable (InputError) -> Void,
    levelHandler: (@Sendable (Float) -> Void)? = nil,
    route: AudioInputRoute? = nil
  ) {
    self.feed = feed
    self.failureHandler = failureHandler
    self.levelHandler = levelHandler
    self.route = route
  }

  func start(outputFormat: AVAudioFormat) throws {
    try recoveryQueue.sync {
      try startOnRecoveryQueue(outputFormat: outputFormat)
    }
  }

  private func startOnRecoveryQueue(outputFormat: AVAudioFormat) throws {
    if feed != nil { route?.setDictationActive(true) }
    stateLock.withLock {
      analyzerFormat = outputFormat
      running = true
      reportedFailure = false
    }
    if let route {
      routeObserver = NotificationCenter.default.addObserver(
        forName: AudioInputRoute.didChange, object: route, queue: nil
      ) { [weak self] _ in self?.recoverFromRouteChange() }
    }
    do {
      try startCapturing(on: audioEngine, into: outputFormat)
    } catch {
      stateLock.withLock {
        running = false
        startupDeadline.cancel()
      }
      stopObservingConfigurationChanges()
      stopObservingRouteChanges()
      audioEngine.stop()
      route?.publish(.failed(error.localizedDescription), generation: stateLock.withLock { captureGeneration })
      if feed != nil { route?.setDictationActive(false) }
      AppLog.audio.error(
        "engine failed to start: \(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
    AppLog.audio.info(
      "capturing at \(self.audioEngine.inputNode.outputFormat(forBus: 0).sampleRate, privacy: .public) Hz"
    )
  }

  /// A format snapshot can be stale before tap installation. Leave negotiation
  /// to the node; conversion follows the format of each delivered buffer.
  private func startCapturing(on engine: AVAudioEngine, into outputFormat: AVAudioFormat) throws {
    let generation = route?.beginCapture()
    let startupGeneration = stateLock.withLock {
      captureGeneration = generation
      return startupDeadline.begin()
    }
    let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
    guard authorization != .denied, authorization != .restricted else {
      throw InputError.permissionDenied
    }
    if let route {
      guard var deviceID = try route.deviceIDForCapture() else { throw InputError.unavailable }
      guard let unit = engine.inputNode.audioUnit else { throw InputError.unavailable }
      let status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &deviceID, UInt32(MemoryLayout.size(ofValue: deviceID))
      )
      guard status == noErr else { throw InputError.routingFailed(status) }
    }
    let inputNode = engine.inputNode
    let hardwareFormat = inputNode.inputFormat(forBus: 0)
    guard Self.hasUsableHardwareInput(hardwareFormat) else {
      throw InputError.unavailable
    }
    // Changing CurrentDevice is our own configuration change, not a failed
    // running engine. Observe only after that write to avoid recovery loops.
    observeConfigurationChanges(of: engine)
    inputNode.removeTap(onBus: 0)

    let converterBox = ConverterBox(outputFormat: outputFormat)
    try Self.installTap(on: inputNode) { [weak self] buffer, _ in
      self?.receive(buffer, converterBox: converterBox, generation: generation,
        startupGeneration: startupGeneration)
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      throw error
    }
    route?.publish(.started, generation: generation)
    // This is a failure deadline, not a retry or a Bluetooth settling delay.
    // Synchronous engine startup does not consume the post-start allowance.
    recoveryQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self else { return }
      if let generation, route?.generation != generation { return }
      let expired = stateLock.withLock {
        running && startupDeadline.expire(generation: startupGeneration)
      }
      if expired {
        reportFailure(.noFirstBuffer, generation: generation, startupGeneration: startupGeneration)
      }
    }
  }

  private func observeConfigurationChanges(of engine: AVAudioEngine) {
    stopObservingConfigurationChanges()
    let observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self, weak engine] _ in
      guard engine?.isRunning == false else { return }
      AppLog.audio.notice("audio route changed; the engine has stopped itself")
      self?.recoverFromRouteChange()
    }
    stateLock.withLock { configurationObserver = observer }
  }

  private func stopObservingConfigurationChanges() {
    let observer = stateLock.withLock { () -> (any NSObjectProtocol)? in
      defer { configurationObserver = nil }
      return configurationObserver
    }
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  private func stopObservingRouteChanges() {
    if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    routeObserver = nil
  }

  /// AVAudioEngine stops itself when the audio hardware changes underneath it
  /// and says so through this notification. Nothing else restarts it, so
  /// without this a session that began just as a headset switched profile
  /// listens to an engine that is no longer running: no levels, no words, and
  /// no error to show for it.
  private func recoverFromRouteChange() {
    let shouldRecover = stateLock.withLock { () -> Bool in
      guard running else { return false }
      guard !recovering else {
        recoveryPending = true
        return false
      }
      recovering = true
      return true
    }
    guard shouldRecover else { return }
    scheduleRecovery()
  }

  private func scheduleRecovery() {
    // Off the notification thread. No settle delay: a fresh engine starts
    // cleanly straight away, and the -10868 that looked like it needed one
    // came from restarting the old engine rather than from being early.
    recoveryQueue.async { [weak self] in
      guard let self else { return }
      rebuildEngine()

      // A change that arrived mid-rebuild describes hardware the new engine
      // never saw, so it gets its own pass rather than being dropped.
      let again = stateLock.withLock { () -> Bool in
        guard running, recoveryPending else {
          recovering = false
          recoveryPending = false
          return false
        }
        recoveryPending = false
        return true
      }
      if again { scheduleRecovery() }
    }
  }

  private func rebuildEngine() {
    let outputFormat = stateLock.withLock { () -> AVAudioFormat? in
      guard running else { return nil }
      return analyzerFormat
    }
    guard let outputFormat else { return }

    // Do not retain the stopped engine across replacement startup. Its HAL
    // resources survive stop(), and overlapping engines can reject a return
    // from Bluetooth to built-in input with kAudioHardwareIllegalOperationError.
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)

    let engine = AVAudioEngine()
    stateLock.withLock { audioEngine = engine }
    do {
      try startCapturing(on: engine, into: outputFormat)
    } catch {
      // Nothing else is coming. Ending the session with a reason beats
      // leaving the shape up in front of a microphone that is not running.
      reportFailure((error as? InputError) ?? .unavailable)
    }
  }

  static func installTap(on node: AVAudioNode, block: @escaping AVAudioNodeTapBlock) throws {
    // macOS 27 reports native tap rejection as NSError. The legacy overload
    // raises an Objective-C exception, which Swift catch cannot contain.
    #if compiler(>=6.4)
    if #available(macOS 27.0, *) {
      try node.__installTap(onBus: 0, bufferSize: 1_024, format: nil, error: (), block: block)
      return
    }
    #endif
    node.installTap(onBus: 0, bufferSize: 1_024, format: nil, block: block)
  }

  static func hasUsableHardwareInput(_ format: AVAudioFormat) -> Bool {
    format.channelCount > 0 && format.sampleRate > 0
  }

  func stop() {
    // Stop cannot interleave with replacement-engine startup and leave an
    // unowned microphone running after the session has ended.
    recoveryQueue.sync { stopOnRecoveryQueue() }
  }

  private func stopOnRecoveryQueue() {
    let shouldStop = stateLock.withLock { () -> Bool in
      guard running else { return false }
      running = false
      startupDeadline.cancel()
      return true
    }

    guard shouldStop else { return }
    stopObservingConfigurationChanges()
    stopObservingRouteChanges()
    let engine = stateLock.withLock { audioEngine }
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    route?.publish(.stopped, generation: stateLock.withLock { captureGeneration })
    if feed != nil { route?.setDictationActive(false) }
  }

  deinit {
    if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    audioEngine.stop()
    if feed != nil, running { route?.setDictationActive(false) }
  }

  private func receive(_ buffer: AVAudioPCMBuffer, converterBox: ConverterBox, generation: UInt64?,
    startupGeneration: UInt64) {
    if let generation, route?.generation != generation { return }
    let acceptsBuffer = stateLock.withLock {
      guard running, !reportedFailure, startupDeadline.generation == startupGeneration else { return false }
      startupDeadline.receive(frameCount: buffer.frameLength, generation: startupGeneration)
      return true
    }
    guard acceptsBuffer else { return }
    publishLevel(of: buffer, generation: generation)
    guard let feed, !stateLock.withLock({ reportedFailure }) else { return }
    do {
      let convertedBuffer = try convert(buffer, using: converterBox)
      if !feed(convertedBuffer) {
        reportFailure(.analyzerBackpressure, generation: generation, startupGeneration: startupGeneration)
      }
    } catch let error as InputError {
      reportFailure(error, generation: generation, startupGeneration: startupGeneration)
    } catch {
      reportFailure(.conversionFailed(error.localizedDescription), generation: generation,
        startupGeneration: startupGeneration)
    }
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

  /// RMS of the first channel (vDSP, so the audio thread barely notices)
  /// mapped to 0–1 over a 50 dB window: a quiet room sits near zero and
  /// speech fills most of the range.
  private func publishLevel(of buffer: AVAudioPCMBuffer, generation: UInt64?) {
    guard levelHandler != nil || route != nil,
       let samples = buffer.floatChannelData?[0],
       buffer.frameLength > 0
    else { return }

    let rms = vDSP.rootMeanSquare(
      UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))
    )
    let db = 20 * log10(max(rms, .leastNormalMagnitude))
    let level = min(1, max(0, (db + 50) / 50))
    levelHandler?(level)
    route?.publish(.level(level), generation: generation)
  }

  private func reportFailure(_ error: InputError, generation: UInt64? = nil,
    startupGeneration: UInt64? = nil) {
    // A retiring tap can finish conversion after its replacement has started.
    // Validate and terminate on the same queue that opens replacement engines.
    recoveryQueue.async { [weak self] in
      guard let self else { return }
      if let generation, route?.generation != generation { return }
      let shouldReport = stateLock.withLock { () -> Bool in
        guard running, !reportedFailure,
          startupGeneration == nil || startupGeneration == startupDeadline.generation else { return false }
        reportedFailure = true
        startupDeadline.cancel()
        return true
      }

      guard shouldReport else { return }
      route?.publish(.failed(error.localizedDescription), generation: generation ?? stateLock.withLock { captureGeneration })
      AppLog.audio.error(
        "microphone failed: \(error.errorDescription ?? "unknown", privacy: .public)"
      )
      failureHandler(error)
    }
  }
}
