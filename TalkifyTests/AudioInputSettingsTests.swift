import AppKit
import SwiftUI
import Testing
@testable import Talkify

@MainActor
@Suite(.serialized)
struct AudioInputSettingsTests {
  @Test func dictationSettingsOffersAnAudioInputControl() async throws {
    let harness = Harness()
    defer { harness.close() }
    try await settle()
    let picker = try #require(find("audio-input-picker", in: harness.window))
    #expect(value(picker, "accessibilityLabel") as? String == "Audio input")
    #expect(value(picker, "accessibilityValue") as? String == "System")
  }

  @Test func disconnectedSelectionRemainsVisibleAndReconnectUpdatesTheRenderedSource() async throws {
    let harness = Harness()
    defer { harness.close() }
    harness.audio.updateInventory(devices: [system, usb], defaultDeviceID: 1)
    harness.audio.selectInput(uid: usb.id)
    try await settle()
    #expect(pickerValue(harness.window) == "USB microphone")
    #expect(contains("Using: USB microphone", in: harness.window))
    harness.audio.updateInventory(devices: [system], defaultDeviceID: 1)
    try await settle()
    #expect(pickerValue(harness.window) == "Unavailable input (usb)")
    #expect(contains("Saved input is disconnected. Using System: Mac microphone. Your preference is kept and will return automatically.", in: harness.window))
    #expect(AppSettings(defaults: harness.defaults).preferredAudioInputUID == usb.id)
    let returned = AudioInputDevice(id: usb.id, name: "USB returned", deviceID: 99)
    harness.audio.updateInventory(devices: [system, returned], defaultDeviceID: 1)
    try await settle()
    #expect(pickerValue(harness.window) == "USB returned")
    #expect(contains("Using: USB returned", in: harness.window))
    #expect(!contains("Saved input is disconnected.", in: harness.window))
  }

  @Test func meterDistinguishesSilenceSignalFailureAndNoAvailableInput() async throws {
    let harness = Harness()
    defer { harness.close() }
    harness.audio.updateInventory(devices: [system], defaultDeviceID: 1)
    harness.audio.selectInput(uid: usb.id)
    harness.audio.route.setDictationActive(true)
    harness.audio.route.publish(.started)
    try await settle()
    #expect(meterValue(harness.window) == "No signal")
    harness.audio.route.publish(.level(0.7))
    try await settle()
    #expect(meterValue(harness.window) == "Signal detected, 70 percent")
    #expect(contains("Using System: Mac microphone", in: harness.window))
    try attachWindow(harness.window, named: "audio-input-fallback")
    harness.audio.route.publish(.failed("Microphone unavailable. Reconnect it or choose another input."))
    try await settle()
    #expect(meterValue(harness.window) == "Microphone unavailable. Reconnect it or choose another input.")
    harness.audio.route.publish(.started)
    harness.audio.updateInventory(devices: [], defaultDeviceID: nil)
    try await settle()
    #expect(meterValue(harness.window) == "Input unavailable")
    #expect(contains("No System input is available", in: harness.window))
    #expect(pickerValue(harness.window) == "Unavailable input (usb)")
  }

  @Test func noFirstBufferFailureRemainsExplicitAfterCaptureStops() async throws {
    let harness = Harness()
    defer { harness.close() }
    harness.audio.updateInventory(devices: [system], defaultDeviceID: 1)
    harness.audio.route.setDictationActive(true)
    let generation = harness.audio.route.beginCapture()
    harness.audio.route.publish(.started, generation: generation)
    let message = MicrophoneInput.InputError.noFirstBuffer.localizedDescription
    harness.audio.route.publish(.failed(message), generation: generation)
    harness.audio.route.publish(.stopped, generation: generation)
    try await settle()
    #expect(meterValue(harness.window) == message)
    #expect(!harness.audio.isMonitoring)
    #expect(harness.audio.level == 0)
    #expect(harness.audio.captureError == message)
  }

  @Test func deniedMicrophonePermissionExplainsHowToEnableIt() async throws {
    let harness = Harness()
    defer { harness.close() }
    harness.audio.updateInventory(devices: [system], defaultDeviceID: 1)
    await harness.audio.startMonitoring()
    try await settle()
    #expect(meterValue(harness.window) == "Microphone access is denied. Enable it in System Settings.")
    #expect(find("audio-input-permission-settings", in: harness.window) != nil)
    try attachWindow(harness.window, named: "audio-input-permission-denied")
  }

  @Test func choosingAnInputThroughThePickerPersistsItsUID() async throws {
    let harness = Harness()
    defer { harness.close() }
    harness.audio.updateInventory(devices: [system, usb], defaultDeviceID: 1)
    try await settle()
    try await chooseInput(character: "u", keyCode: 32, in: harness.window)
    #expect(harness.settings.preferredAudioInputUID == usb.id)
    #expect(AppSettings(defaults: harness.defaults).preferredAudioInputUID == usb.id)
    #expect(pickerValue(harness.window) == "USB microphone")
    // AppKit retains type-ahead across consecutive menu openings.
    try await Task.sleep(for: .seconds(1.5))
    try await chooseInput(character: "s", keyCode: 1, in: harness.window)
    #expect(AppSettings(defaults: harness.defaults).preferredAudioInputUID == nil)
    #expect(pickerValue(harness.window) == "System")
    harness.audio.updateInventory(devices: [system, usb], defaultDeviceID: 2)
    try await settle()
    #expect(contains("Using System: USB microphone", in: harness.window))
  }

  private func chooseInput(character: String, keyCode: UInt16, in window: NSWindow) async throws {
    let picker = try #require(find("audio-input-picker", in: window))

    let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
      MainActor.assumeIsolated {

        for (characters, code) in [(character, keyCode), ("\r", UInt16(36))] {
          for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
              context: nil, characters: characters, charactersIgnoringModifiers: characters,
              isARepeat: false, keyCode: code) {
              NSApp.postEvent(event, atStart: false)
            }
          }
        }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate() }
    press(picker)
    try await Task.sleep(for: .milliseconds(500))
  }

  @Test func closingTheRealWindowCancelsPendingPermission() async throws {
    let gate = AudioInputSelectionTests.PermissionGate()
    let harness = Harness(fullSettings: true, request: { await gate.request() })
    defer { harness.close() }
    try await settle()
    let dictation = try #require(descendants(harness.window.contentView as Any).first {
      value($0, "accessibilityLabel") as? String == "Dictation"
    })
    press(dictation)
    for _ in 0..<30 {
      if await gate.isWaiting { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await gate.isWaiting)
    harness.window.close()
    await gate.grant()
    try await settle()
    #expect(!harness.audio.isMonitoring)
    #expect(harness.audio.captureError == nil, "late permission must not open an engine")
  }

  private func attachWindow(_ window: NSWindow, named name: String) throws {
    let view = try #require(window.contentView)
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    Attachment.record(data, named: "\(name).png")
  }

  @Test func retainedSettingsWindowMonitorsOnlyTheVisibleDictationSection() async throws {
    let requests = RequestCounter()
    let capture = AudioInputLevelMonitorTests.Capture()
    let harness = Harness(fullSettings: true, capture: capture, request: { await requests.request() })
    defer { harness.close() }
    try await settle()
    #expect(await requests.count == 0)
    let dictation = try #require(descendants(harness.window.contentView as Any).first {
      value($0, "accessibilityLabel") as? String == "Dictation"
    })
    press(dictation)
    try await settle()
    #expect(await requests.count == 1)
    #expect(capture.waitForStarts(1))
    #expect(capture.counts.starts == 1)
    harness.runtime.isDictating = true
    try await settle()
    #expect(contains("Insertion and History changes apply to the next Direct Dictation session.", in: harness.window))
    try attachWindow(harness.window, named: "audio-input-settings-window")
    harness.audio.route.setDictationActive(true)
    #expect(capture.counts.stops == 1)
    harness.audio.route.publish(.started)
    try await settle()
    harness.window.close()
    #expect(!harness.runtime.isSettingsVisible)
    #expect(harness.audio.route.isDictationActive)
    harness.controller?.show()
    try await settle()
    #expect(harness.runtime.isSettingsVisible)
    let reopenedRequests = await requests.count
    #expect(reopenedRequests >= 2, "activation may also recheck permission")
    #expect(capture.counts.starts == 1, "reopening cannot compete with dictation")
    for _ in 0..<5 {
      harness.window.close()
      harness.controller?.show()
      try await settle()
      #expect(harness.runtime.isSettingsVisible)
      #expect(capture.counts.starts == 1, "repeated presentations cannot interrupt dictation")
    }
    harness.audio.route.setDictationActive(false)
    #expect(capture.waitForStarts(2))
    #expect(capture.counts.starts == 2, "visible Settings resumes idle capture")
    let sounds = try #require(descendants(harness.window.contentView as Any).first {
      value($0, "accessibilityLabel") as? String == "Sounds"
    })
    press(sounds)
    try await settle()
    #expect(capture.waitForStops(2))
    #expect(capture.counts.stops == 2, "leaving Dictation releases idle capture")
    harness.audio.route.setDictationActive(false)
    harness.audio.route.publish(.stopped)
    try await settle()
    #expect(!harness.audio.isMonitoring)
    harness.audio.updateInventory(devices: [system], defaultDeviceID: 1)
    #expect(harness.audio.route.deviceID == 1, "hardware listeners/model remain usable")
  }

  @Test func revokedPermissionStopsIdleMonitoringAndPreventsRouteRestarts() async throws {
    let requests = RequestCounter()
    let capture = AudioInputLevelMonitorTests.Capture()
    let harness = Harness(fullSettings: true, capture: capture, request: { await requests.request() })
    defer { harness.close() }
    try await settle()
    let dictation = try #require(descendants(harness.window.contentView as Any).first {
      value($0, "accessibilityLabel") as? String == "Dictation"
    })
    press(dictation)
    try await settle()
    #expect(capture.waitForStarts(1))
    #expect(capture.counts.starts == 1)
    await requests.deny()
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    try await settle()
    #expect(harness.audio.isMicrophoneAccessDenied)
    #expect(capture.waitForStops(capture.counts.starts))
    let counts = capture.counts
    #expect(counts.stops == counts.starts, "revoking permission must release idle capture")
    harness.audio.updateInventory(devices: [system], defaultDeviceID: 1)
    #expect(capture.counts.starts == counts.starts, "denied monitoring cannot restart on a device change")
    #expect(meterValue(harness.window) == "Microphone access is denied. Enable it in System Settings.")
  }

  actor RequestCounter {
    var count = 0
    var allowed = true
    func request() -> Bool { count += 1; return allowed }
    func deny() { allowed = false }
  }

  private func press(_ node: NSObject) {
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard node.responds(to: selector), let implementation = node.method(for: selector) else {
      Issue.record("Control does not expose a press action")
      return
    }
    typealias Action = @convention(c) (AnyObject, Selector) -> Bool
    _ = unsafeBitCast(implementation, to: Action.self)(node, selector)
  }

  private func meterValue(_ window: NSWindow) -> String? {
    find("audio-input-meter", in: window).flatMap {
      (value($0, "accessibilityLabel") as? String)?.replacingOccurrences(of: "Input level: ", with: "")
    }
  }

  private var system: AudioInputDevice { .init(id: "mac", name: "Mac microphone", deviceID: 1) }
  private var usb: AudioInputDevice { .init(id: "usb", name: "USB microphone", deviceID: 2) }

  private func settle() async throws {
    try await Task.sleep(for: .milliseconds(150))
  }

  private func pickerValue(_ window: NSWindow) -> String? {
    find("audio-input-picker", in: window).flatMap { value($0, "accessibilityValue") as? String }
  }

  private func find(_ identifier: String, in window: NSWindow) -> NSObject? {
    descendants(window.contentView as Any).first {
      value($0, "accessibilityIdentifier") as? String == identifier
    }
  }

  private func contains(_ text: String, in window: NSWindow) -> Bool {
    descendants(window.contentView as Any).contains {
      (value($0, "accessibilityValue") as? String)?.contains(text) == true
        || (value($0, "accessibilityLabel") as? String)?.contains(text) == true
    }
  }

  // SwiftUI exposes the public accessibility selectors without declaring
  // NSAccessibilityProtocol conformance on its nodes.
  private func value(_ node: NSObject, _ attribute: String) -> Any? {
    let selector = NSSelectorFromString(attribute)
    guard node.responds(to: selector) else { return nil }
    return node.perform(selector)?.takeUnretainedValue()
  }

  private func descendants(_ element: Any) -> [NSObject] {
    guard let node = element as? NSObject else { return [] }
    return [node] + ((value(node, "accessibilityChildren") as? [Any]) ?? []).flatMap { descendants($0) }
  }

  @MainActor
  private final class Harness {
    let defaults: UserDefaults
    let settings: AppSettings
    let audio: AudioInputController
    let window: NSWindow
    let runtime = SettingsRuntimeState()
    let controller: SettingsWindowController?
    private let suite = "AudioInputSettingsTests-\(UUID().uuidString)"

    init(fullSettings: Bool = false, capture: AudioInputLevelMonitorTests.Capture? = nil,
      request: @escaping @Sendable () async -> Bool = { false }) {
      defaults = UserDefaults(suiteName: suite)!
      settings = AppSettings(defaults: defaults)
      audio = AudioInputController(settings: settings, observeHardware: false,
        makeLevelMonitor: { route in
          if let capture { return AudioInputLevelMonitor(route: route, makeCapture: { _, _ in capture }) }
          return AudioInputLevelMonitor(route: route)
        },
        requestMicrophoneAccess: request)
      if fullSettings {
        controller = SettingsWindowController(settings: settings, sounds: HUDSounds(), runtimeState: runtime,
          recognizers: RecognizerStore.live(settings: settings),
          usageTracker: UsageTracker(store: UsageStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "AudioInputSettingsTests-\(UUID().uuidString).json"))),
          updater: SparkleUpdaterService(), launchAtLogin: LaunchAtLoginService(), audioInput: audio)
        window = controller!.window!
      } else {
        controller = nil
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView {
          DictationSettingsView(settings: settings, audioInput: audio).padding(16)
        }
        .frame(width: 600, height: 700)
        .background(SettingsTheme.background)
        .tint(SettingsTheme.accent)
        .preferredColorScheme(.dark))
      }
      NSApp.setActivationPolicy(.regular)
      if let controller { controller.show() } else { window.makeKeyAndOrderFront(nil) }
      NSApp.activate()
      AXUIElementSetAttributeValue(AXUIElementCreateApplication(getpid()),
        "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
      window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
      audio.stop()
      window.close()
      defaults.removePersistentDomain(forName: suite)
    }
  }
}
