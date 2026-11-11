import Foundation
import Testing
@testable import Talkify

@MainActor
struct AudioInputSelectionTests {
  actor PermissionGate {
    private var reply: CheckedContinuation<Bool, Never>?
    func request() async -> Bool {
      await withCheckedContinuation { reply = $0 }
    }
    var isWaiting: Bool { reply != nil }
    func grant() { reply?.resume(returning: true); reply = nil }
  }

  @Test func closingSettingsWhilePermissionIsPendingCannotStartCaptureAfterward() async throws {
    let name = "AudioInputPendingPermissionTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let gate = PermissionGate()
    let controller = AudioInputController(
      settings: AppSettings(defaults: defaults), observeHardware: false,
      requestMicrophoneAccess: { await gate.request() }
    )
    let task = Task { await controller.startMonitoring() }
    while !(await gate.isWaiting) { await Task.yield() }
    controller.stopMonitoring()
    await gate.grant()
    await task.value
    #expect(!controller.isMonitoring)
    #expect(controller.captureError == nil, "no engine was opened after the view closed")
    controller.stop()
  }

  @Test func sharedCaptureLevelsAndFailuresReachSettingsWithoutAnotherCapture() async throws {
    let name = "AudioInputLevelsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let controller = AudioInputController(settings: AppSettings(defaults: defaults), observeHardware: false)
    controller.route.setDictationActive(true)
    controller.route.publish(.started)
    controller.route.publish(.level(0.7))
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.isMonitoring)
    #expect(controller.level == 0.7)
    controller.stopMonitoring()
    #expect(controller.isMonitoring, "closing Settings does not stop dictation")
    controller.route.publish(.failed("capture unavailable"))
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.captureError == "capture unavailable")
    #expect(!controller.isMonitoring)
    #expect(controller.level == 0)
    controller.route.setDictationActive(false)
    controller.stop()
  }

  @Test func changingInputRejectsQueuedLevelsFromThePreviousSource() async throws {
    let name = "AudioInputQueuedLevelsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let controller = AudioInputController(settings: AppSettings(defaults: defaults), observeHardware: false)
    defer { controller.stop() }
    let one = AudioInputDevice(id: "one", name: "One", deviceID: 1)
    let two = AudioInputDevice(id: "two", name: "Two", deviceID: 2)
    controller.updateInventory(devices: [one, two], defaultDeviceID: 1)
    controller.route.setDictationActive(true)
    controller.route.publish(.started)
    controller.route.publish(.level(0.9))
    // Hold the main actor until the source label has changed.
    controller.selectInput(uid: two.id)
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.effectiveInput == two)
    #expect(controller.level == 0, "One's queued signal cannot appear under Two")
    #expect(!controller.isMonitoring, "a replacement engine has not started yet")
    controller.route.publish(.started)
    controller.route.publish(.level(0.2))
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.isMonitoring)
    #expect(controller.level == 0.2)
  }

  @Test func replacingATapRejectsLateEventsEvenWithoutChangingDevice() async throws {
    let name = "AudioInputTapGenerationTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let controller = AudioInputController(settings: AppSettings(defaults: defaults), observeHardware: false)
    defer { controller.stop() }
    controller.route.setDictationActive(true)
    let old = controller.route.beginCapture()
    controller.route.publish(.started, generation: old)
    controller.route.publish(.level(0.8), generation: old)
    let replacement = controller.route.beginCapture()
    controller.route.publish(.started, generation: replacement)
    controller.route.publish(.level(0.2), generation: replacement)
    controller.route.publish(.level(0.9), generation: old)
    controller.route.publish(.failed("retired capture"), generation: old)
    controller.route.publish(.stopped, generation: old)
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.isMonitoring)
    #expect(controller.level == 0.2)
    #expect(controller.captureError == nil)
  }

  @Test func restartingWhileDisconnectedRetainsThePreferenceThroughDefaultChangesAndRestoration() throws {
    let name = "AudioInputRestartTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let system = AudioInputDevice(id: "system", name: "System microphone", deviceID: 1)
    let usb = AudioInputDevice(id: "usb", name: "USB", deviceID: 2)
    let other = AudioInputDevice(id: "other", name: "Other System input", deviceID: 3)
    var controller = AudioInputController(settings: AppSettings(defaults: defaults), observeHardware: false)
    #expect(controller.preferredInputUID == nil)
    controller.updateInventory(devices: [system, usb], defaultDeviceID: 1)
    #expect(controller.effectiveInput == system)
    controller.updateInventory(devices: [system, usb], defaultDeviceID: 2)
    #expect(controller.effectiveInput == usb)
    #expect(defaults.string(forKey: "preferredAudioInputUID") == nil)
    controller.selectInput(uid: usb.id)
    controller.stop()
    // Recreate the application's preference/model boundary, not the OS process.
    controller = AudioInputController(settings: AppSettings(defaults: defaults), observeHardware: false)
    controller.updateInventory(devices: [system, usb], defaultDeviceID: 1)
    #expect(controller.effectiveInput == usb)
    controller.updateInventory(devices: [system], defaultDeviceID: 1)
    #expect(controller.effectiveInput == system)
    controller.stop()
    controller = AudioInputController(settings: AppSettings(defaults: defaults), observeHardware: false)
    defer { controller.stop() }
    controller.updateInventory(devices: [system], defaultDeviceID: 1)
    #expect(!controller.isPreferredAvailable)
    #expect(controller.effectiveInput == system)
    controller.updateInventory(devices: [system, other], defaultDeviceID: 3)
    #expect(controller.effectiveInput == other)
    controller.updateInventory(devices: [], defaultDeviceID: nil)
    #expect(controller.effectiveInput == nil)
    #expect(defaults.string(forKey: "preferredAudioInputUID") == usb.id)
    let returned = AudioInputDevice(id: usb.id, name: "USB returned", deviceID: 99)
    controller.updateInventory(devices: [other, returned], defaultDeviceID: 3)
    #expect(controller.effectiveInput == returned)
    #expect(controller.route.deviceID == 99)
    #expect(controller.preferredInputUID == usb.id)
    #expect(defaults.string(forKey: "preferredAudioInputUID") == usb.id)
  }

  @Test func deniedPermissionLeavesThePreferenceAndCaptureUntouched() async throws {
    let name = "AudioInputPermissionTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    settings.preferredAudioInputUID = "offline-usb"
    let controller = AudioInputController(
      settings: settings, observeHardware: false, requestMicrophoneAccess: { false }
    )
    await controller.startMonitoring()
    #expect(controller.captureError != nil)
    #expect(!controller.isMonitoring)
    #expect(controller.level == 0)
    #expect(controller.preferredInputUID == "offline-usb")
    #expect(!controller.isPreferredAvailable)
    controller.stopMonitoring()
    controller.stop()
  }

  @Test func recoveryResolvesLiveHardwareBeforeTheUIReceivesAnUnplugNotification() throws {
    let system = AudioInputDevice(id: "built-in", name: "Built-in", deviceID: 1)
    let route = AudioInputRoute(readHardware: {
      CoreAudioInputDevices.Snapshot(devices: [system], defaultDeviceID: 1)
    })
    route.update(deviceID: 2, preferredUID: "unplugged-usb")
    #expect(route.deviceID == 2, "the UI has not reconciled its inventory yet")
    #expect(try route.deviceIDForCapture() == 1, "capture must resolve the live fallback")
    route.invalidate()
    #expect(try route.deviceIDForCapture() == nil, "shutdown cannot reopen the live default")
  }

  final class Hardware: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CoreAudioInputDevices.Snapshot
    init(_ value: CoreAudioInputDevices.Snapshot) { self.value = value }
    var snapshot: CoreAudioInputDevices.Snapshot {
      get { lock.withLock { value } }
      set { lock.withLock { value = newValue } }
    }
  }

  @Test func reconnectNotifiesCaptureAfterRecoveryBeatTheInventoryRefresh() throws {
    let system = AudioInputDevice(id: "system", name: "System", deviceID: 1)
    let usb = AudioInputDevice(id: "usb", name: "USB", deviceID: 2)
    let hardware = Hardware(.init(devices: [system, usb], defaultDeviceID: 1))
    let route = AudioInputRoute(readHardware: { hardware.snapshot })
    route.update(deviceID: 2, preferredUID: usb.id)
    #expect(try route.deviceIDForCapture() == 2)
    hardware.snapshot = .init(devices: [system], defaultDeviceID: 1)
    #expect(try route.deviceIDForCapture() == 1)
    let notifications = AudioInputLevelMonitorTests.Capture()
    let observer = NotificationCenter.default.addObserver(
      forName: AudioInputRoute.didChange, object: route, queue: nil
    ) { _ in notifications.stop() }
    defer { NotificationCenter.default.removeObserver(observer) }
    hardware.snapshot = .init(devices: [system, usb], defaultDeviceID: 1)
    route.update(deviceID: 2, preferredUID: usb.id)
    #expect(notifications.counts.stops == 1, "reconnection must dislodge the fallback capture")
  }

  @Test func dictationActivityDefaultsToInactiveAndCanBeReleased() {
    let route = AudioInputRoute()
    #expect(!route.isDictationActive)
    route.setDictationActive(true)
    #expect(route.isDictationActive)
    route.setDictationActive(false)
    #expect(!route.isDictationActive)
  }

  @Test func systemFollowsDefaultChangesAndNeverSelectsAnArbitraryInput() {
    let one = AudioInputDevice(id: "one", name: "One", deviceID: 1)
    let two = AudioInputDevice(id: "two", name: "Two", deviceID: 2)
    #expect(AudioInputSelection(preferredUID: nil, devices: [one, two], defaultDeviceID: 1)
      .effectiveInput == one)
    #expect(AudioInputSelection(preferredUID: nil, devices: [one, two], defaultDeviceID: 2)
      .effectiveInput == two)
    #expect(AudioInputSelection(preferredUID: nil, devices: [one], defaultDeviceID: nil)
      .effectiveInput == nil)
    #expect(AudioInputSelection(preferredUID: "missing", devices: [], defaultDeviceID: 0)
      .effectiveInput == nil)
    #expect(AudioInputSelection(preferredUID: one.id, devices: [one, two], defaultDeviceID: 2)
      .effectiveInput == one)
  }

  @Test func controllerPreservesPreferenceThroughFallbackAndUsesNewIDOnReconnect() throws {
    let name = "AudioInputControllerTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    let controller = AudioInputController(settings: settings, observeHardware: false)
    let one = AudioInputDevice(id: "one", name: "One", deviceID: 1)
    let usb = AudioInputDevice(id: "usb", name: "USB", deviceID: 2)
    controller.updateInventory(devices: [one, usb], defaultDeviceID: 1)
    controller.selectInput(uid: usb.id)
    #expect(controller.route.deviceID == 2)
    controller.updateInventory(devices: [one], defaultDeviceID: 1)
    #expect(controller.preferredInputUID == usb.id)
    #expect(!controller.isPreferredAvailable)
    #expect(controller.route.deviceID == 1)
    #expect(AppSettings(defaults: defaults).preferredAudioInputUID == usb.id)
    let reconnected = AudioInputDevice(id: "usb", name: "USB renamed", deviceID: 99)
    controller.updateInventory(devices: [one, reconnected], defaultDeviceID: 1)
    #expect(controller.effectiveInput == reconnected)
    #expect(controller.route.deviceID == 99)
    controller.selectInput(uid: nil)
    controller.updateInventory(devices: [one, reconnected], defaultDeviceID: 99)
    #expect(controller.isUsingSystem)
    #expect(controller.effectiveInput == reconnected)
    controller.stop()
    #expect(controller.route.deviceID == nil)
  }

  @Test func missingPreferredInputFallsBackWithoutLosingItsUIDAndReconnects() {
    let builtIn = AudioInputDevice(id: "built-in", name: "Mac microphone", deviceID: 1)
    let usb = AudioInputDevice(id: "usb-stable", name: "USB", deviceID: 2)
    let missing = AudioInputSelection(preferredUID: usb.id, devices: [builtIn], defaultDeviceID: 1)
    #expect(!missing.isPreferredAvailable)
    #expect(missing.isUsingSystem)
    #expect(missing.effectiveInput == builtIn)
    let restored = AudioInputSelection(
      preferredUID: usb.id, devices: [builtIn, usb], defaultDeviceID: 1
    )
    #expect(restored.isPreferredAvailable)
    #expect(!restored.isUsingSystem)
    #expect(restored.effectiveInput == usb)
  }

  @Test func preferredInputDefaultsToSystemAndRoundTripsAStableUID() throws {
    let name = "AudioInputSelectionTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.preferredAudioInputUID == nil)
    settings.preferredAudioInputUID = "USB-device-stable-uid"
    #expect(defaults.string(forKey: "preferredAudioInputUID") == "USB-device-stable-uid")
    #expect(AppSettings(defaults: defaults).preferredAudioInputUID == "USB-device-stable-uid")
    settings.preferredAudioInputUID = nil
    #expect(AppSettings(defaults: defaults).preferredAudioInputUID == nil)
  }
}
