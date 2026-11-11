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
