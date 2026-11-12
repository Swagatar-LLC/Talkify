import AppKit
import SwiftUI
import Testing

@testable import Talkify

/// Draws each Recognizer pane state to a PNG, for review on a Mac that can only show one
/// of them live. Runs only when `TALKIFY_RENDER_DIR` names a folder.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TALKIFY_RENDER_DIR"] != nil))
struct RecognizerPaneRenderTests {
  private typealias Fixtures = RecognizerPreviewFixtures

  @Test func renderEveryState() throws {
    let folder = URL(filePath: try #require(ProcessInfo.processInfo.environment["TALKIFY_RENDER_DIR"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let old = OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 2)

    let panes: [(String, RecognizerStore)] = [
      ("pane-available", Fixtures.store()),
      ("pane-proposed", Fixtures.store(model: Fixtures.whisper(status: .proposed))),
      ("pane-older-system", Fixtures.store(systemVersion: old)),
      ("pane-downloading", Fixtures.store(install: Fixtures.progress(.download, fraction: 0.42))),
      ("pane-in-use", Fixtures.store(installed: true, selected: true)),
      ("notice-files-missing", Fixtures.store(selected: true, fallback: .filesMissing)),
      ("notice-hash-mismatch", Fixtures.store(installed: true, selected: true, fallback: .hashMismatch)),
      ("notice-revoked", Fixtures.store(
        model: Fixtures.whisper(status: .revoked, revoked: .init(
          date: "2026-12-01", reason: "The conversion was found to bundle custom layers.", severity: .block)),
        installed: true, fallback: .revoked("The conversion was found to bundle custom layers."))),
      ("notice-unsupported-language", Fixtures.store(
        installed: true, selected: true, fallback: .unsupportedLanguage("de"))),
      ("notice-load-error", Fixtures.store(
        installed: true, selected: true,
        fallback: .loadFailed("Core ML could not allocate memory for the audio encoder."))),
    ]
    for (name, store) in panes {
      try write(
        ScrollView { RecognizerSettingsView(store: store).frame(width: 620).padding(30) },
        size: NSSize(width: 680, height: 620),
        to: folder.appending(path: name + ".png"))
    }

    let sheets: [(String, RecognizerStore)] = [
      ("sheet-disclosure", Fixtures.store()),
      ("sheet-downloading", Fixtures.store(install: Fixtures.progress(.download, fraction: 0.42))),
      ("sheet-verifying", Fixtures.store(install: Fixtures.progress(.verify))),
      ("sheet-preparing", Fixtures.store(installed: true, install: Fixtures.progress(.prepare))),
      ("sheet-ready", Fixtures.store(installed: true, install: Fixtures.progress(.prepare, outcome: .ready))),
      ("sheet-prepare-failed", Fixtures.store(installed: true, install: Fixtures.progress(
        .prepare, outcome: .failed(.prepare, "Core ML could not compile the audio encoder.")))),
    ]
    for (name, store) in sheets {
      try write(
        RecognizerDownloadSheet(store: store, model: store.catalog.models[0], onClose: {}),
        size: NSSize(width: 500, height: 420),
        to: folder.appending(path: name + ".png"))
    }
  }

  /// The whole Settings window as the app builds it, on the Recognizer section, with the
  /// live store: the bundled catalog, this Mac's real system version and install folder.
  @Test func renderTheLiveSettingsWindow() throws {
    let folder = URL(filePath: try #require(ProcessInfo.processInfo.environment["TALKIFY_RENDER_DIR"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let settings = AppSettings.previewStore()
    let view = SettingsView(
      settings: settings,
      sounds: HUDSounds(),
      runtimeState: SettingsRuntimeState(),
      recognizers: RecognizerStore.live(settings: settings),
      usageTracker: UsageTracker(store: UsageStore(
        fileURL: FileManager.default.temporaryDirectory
          .appending(path: "RecognizerPaneRenderTests-" + UUID().uuidString + ".json")
      )),
      updater: SparkleUpdaterService(),
      launchAtLogin: LaunchAtLoginService(),
      audioInput: AudioInputController(settings: settings, observeHardware: false),
      initialSection: .recognizer,
      onClose: {}
    )
    let version = SystemRequirement.describe(ProcessInfo.processInfo.operatingSystemVersion)
    try write(view, size: NSSize(width: 860, height: 600), to: folder.appending(path: "live-settings-macos-\(version).png"))
  }

  /// Through a real window, so AppKit-backed controls (progress, buttons) draw as they do
  /// in the app rather than as `ImageRenderer` placeholders.
  private func write(_ view: some View, size: NSSize, to url: URL) throws {
    let root = view
      .frame(width: size.width, height: size.height, alignment: .topLeading)
      .background(SettingsTheme.background)
      .preferredColorScheme(.dark)
      .tint(SettingsTheme.accent)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
  }
}
