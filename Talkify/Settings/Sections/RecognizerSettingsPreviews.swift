import SwiftUI

/// Every state the Recognizer pane and its sheet can be in, each from a store seeded with
/// that state and a client that touches nothing.
@MainActor
enum RecognizerPreviewFixtures {
  /// The bundled Whisper entry, with the status the preview needs. The bundled file lists
  /// it as proposed until review, so `available` here shows the row Download offers.
  static func whisper(
    status: CatalogModel.Status = .available,
    revoked: CatalogModel.Revocation? = nil
  ) -> CatalogModel {
    var model = (try? Catalog.bundled().models.first) ?? placeholder
    model.status = status
    model.revoked = revoked
    return model
  }

  static func store(
    model: CatalogModel = whisper(),
    installed: Bool = false,
    selected: Bool = false,
    install: InstallProgress? = nil,
    fallback: RecognizerFallback? = nil,
    systemVersion: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
  ) -> RecognizerStore {
    let settings = AppSettings.previewStore()
    settings.recognizerModelID = selected ? model.id : ""
    let store = RecognizerStore(
      catalog: Catalog(schemaVersion: 1, catalogVersion: 1, models: [model]),
      settings: settings,
      client: RecognizerStore.Client(
        isInstalled: { _ in installed },
        download: { _, _ in },
        verify: { _ in URL(filePath: "/dev/null") },
        prepare: { _, _ in },
        delete: { _ in }
      ),
      systemVersion: systemVersion,
      installs: install.map { [model.id: $0] } ?? [:],
      notice: fallback.map { RecognizerNotice(modelID: model.id, modelName: model.displayName, fallback: $0) }
    )
    return store
  }

  static func progress(
    _ stage: InstallProgress.Stage,
    fraction: Double = 0,
    outcome: InstallProgress.Outcome? = nil
  ) -> InstallProgress {
    let total = whisper().totalBytes
    return InstallProgress(
      stage: stage,
      receivedBytes: stage == .download ? Int64(Double(total) * fraction) : total,
      totalBytes: total,
      startedAt: Date(timeIntervalSince1970: 1_794_366_000),
      outcome: outcome
    )
  }

  private static let placeholder = CatalogModel(
    id: "preview", displayName: "Preview model", status: .available,
    publisher: .init(weights: "Preview", conversion: nil), sources: [], mirrors: [],
    totalBytes: 600_000_000, format: .coreMLCompiled, runtime: .init(id: "whisperkit", minVersion: "1"),
    licence: .init(spdx: "MIT", url: "https://example.com", attribution: nil), languages: ["en"],
    minHardware: .init(arch: "arm64", minimumSystemVersion: "26.7", memoryGB: nil, neuralEngine: true),
    measured: nil, review: nil, revoked: nil
  )
}

/// The pane as Settings hosts it: its dark backdrop and width.
private struct RecognizerPanePreview: View {
  let store: RecognizerStore

  var body: some View {
    ScrollView {
      RecognizerSettingsView(store: store)
        .frame(width: 620)
        .padding(30)
    }
    .frame(width: 680, height: 560)
    .background(SettingsTheme.background)
    .preferredColorScheme(.dark)
    .tint(SettingsTheme.accent)
  }
}

private struct RecognizerSheetPreview: View {
  let store: RecognizerStore

  var body: some View {
    RecognizerDownloadSheet(store: store, model: store.catalog.models[0], onClose: {})
  }
}

#Preview("Pane · available, not downloaded") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store())
}

#Preview("Pane · proposed (bundled catalog today)") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store(model: RecognizerPreviewFixtures.whisper(status: .proposed)))
}

#Preview("Pane · macOS 26.6.2, Apple Speech only") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store(
    systemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 2)
  ))
}

#Preview("Pane · downloading") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store(install: RecognizerPreviewFixtures.progress(.download, fraction: 0.42)))
}

#Preview("Pane · installed") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store(installed: true))
}

#Preview("Pane · in use") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store(installed: true, selected: true))
}

#Preview("Pane · withdrawn, advisory") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store(
    model: RecognizerPreviewFixtures.whisper(revoked: .init(
      date: "2026-12-01", reason: "A newer conversion fixes a decoding loop.", severity: .advisory)),
    installed: true, selected: true
  ))
}

#Preview("Pane · withdrawn, blocked") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store(
    model: RecognizerPreviewFixtures.whisper(status: .revoked, revoked: .init(
      date: "2026-12-01", reason: "The conversion was found to bundle custom layers.", severity: .block)),
    installed: true, fallback: .revoked("The conversion was found to bundle custom layers.")
  ))
}

#Preview("Notice · files missing") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store(selected: true, fallback: .filesMissing))
}

#Preview("Notice · hash mismatch") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store(installed: true, selected: true, fallback: .hashMismatch))
}

#Preview("Notice · unsupported language") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store(installed: true, selected: true, fallback: .unsupportedLanguage("de")))
}

#Preview("Notice · load error") {
  RecognizerPanePreview(store: RecognizerPreviewFixtures.store(
    installed: true, selected: true,
    fallback: .loadFailed("Core ML could not allocate memory for the audio encoder.")
  ))
}

#Preview("Sheet · disclosure") {
  RecognizerSheetPreview(store: RecognizerPreviewFixtures.store())
}

#Preview("Sheet · downloading") {
  RecognizerSheetPreview(store: RecognizerPreviewFixtures.store(install: RecognizerPreviewFixtures.progress(.download, fraction: 0.42)))
}

#Preview("Sheet · verifying") {
  RecognizerSheetPreview(store: RecognizerPreviewFixtures.store(install: RecognizerPreviewFixtures.progress(.verify)))
}

#Preview("Sheet · preparing") {
  RecognizerSheetPreview(store: RecognizerPreviewFixtures.store(installed: true, install: RecognizerPreviewFixtures.progress(.prepare)))
}

#Preview("Sheet · ready") {
  RecognizerSheetPreview(store: RecognizerPreviewFixtures.store(installed: true, install: RecognizerPreviewFixtures.progress(.prepare, outcome: .ready)))
}

#Preview("Sheet · download failed") {
  RecognizerSheetPreview(store: RecognizerPreviewFixtures.store(install: RecognizerPreviewFixtures.progress(
    .download, fraction: 0.3,
    outcome: .failed(.download, CatalogInstallError.hashMismatch(path: "weight.bin").localizedDescription)
  )))
}

#Preview("Sheet · prepare failed") {
  RecognizerSheetPreview(store: RecognizerPreviewFixtures.store(installed: true, install: RecognizerPreviewFixtures.progress(
    .prepare, outcome: .failed(.prepare, "Core ML could not compile the audio encoder.")
  )))
}
