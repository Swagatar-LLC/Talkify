import AppKit
import SwiftUI

private final class TalkifySettingsWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func cancelOperation(_ sender: Any?) {
    close()
  }
}

/// Owns one fixed, borderless Settings surface for the app's lifetime.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
  private static let windowSize = NSSize(width: 860, height: 600)
  private var hasPositionedWindow = false
  private var audioInput: AudioInputController?
  private var runtimeState: SettingsRuntimeState?

  convenience init(
    settings: AppSettings,
    sounds: HUDSounds,
    runtimeState: SettingsRuntimeState,
    recognizers: RecognizerStore,
    usageTracker: UsageTracker,
    updater: SparkleUpdaterService,
    launchAtLogin: LaunchAtLoginService,
    audioInput: AudioInputController
  ) {
    let window = TalkifySettingsWindow(
      contentRect: NSRect(origin: .zero, size: Self.windowSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let hosting = NSHostingController(
      rootView: SettingsView(
        settings: settings,
        sounds: sounds,
        runtimeState: runtimeState,
        recognizers: recognizers,
        usageTracker: usageTracker,
        updater: updater,
        launchAtLogin: launchAtLogin,
        audioInput: audioInput,
        onClose: { [weak window] in window?.close() }
      )
    )

    window.contentViewController = hosting
    window.title = "Talkify Settings"
    window.level = .normal
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.isMovable = true
    window.isMovableByWindowBackground = false
    window.isReleasedWhenClosed = false
    window.minSize = Self.windowSize
    window.maxSize = Self.windowSize
    window.setContentSize(Self.windowSize)
    self.init(window: window)
    self.audioInput = audioInput
    self.runtimeState = runtimeState
    window.delegate = self
  }

  func show() {
    guard let window else { return }
    if !hasPositionedWindow {
      positionOnPointerDisplay(window)
      hasPositionedWindow = true
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    if runtimeState?.isSettingsVisible == false { runtimeState?.settingsPresentation += 1 }
    runtimeState?.isSettingsVisible = true
  }

  func windowWillClose(_ notification: Notification) {
    runtimeState?.isSettingsVisible = false
    audioInput?.stopMonitoring()
  }

  private func positionOnPointerDisplay(_ window: NSWindow) {
    let pointer = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    guard let visibleFrame = screen?.visibleFrame else {
      window.center()
      return
    }

    window.setFrameOrigin(
      NSPoint(
        x: visibleFrame.midX - window.frame.width / 2,
        y: visibleFrame.midY - window.frame.height / 2
      )
    )
  }
}
