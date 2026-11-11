import Foundation

extension RecognizerStore.Client {
  /// The real disk, network and runtime: `CatalogInstaller` for files, and the runtime the
  /// catalog entry names for Prepare.
  static func live(installer: CatalogInstaller) -> Self {
    Self(
      isInstalled: { model in
        FileManager.default.fileExists(atPath: installer.installFolder(for: model).path)
      },
      download: { model, progress in
        _ = try await installer.install(model, progress: progress)
      },
      verify: { model in
        // A full re-hash: 0.3 s for the 648 MB Whisper entry, kept off the main actor.
        try await Task.detached(priority: .userInitiated) {
          try installer.verifiedFolder(for: model)
        }.value
      },
      prepare: { model, folder in
        guard model.runtime.id == WhisperRecognizer.runtimeID else {
          throw WhisperRecognizer.Failure.unsupportedModel
        }
        // The first load compiles for the Neural Engine (153-234 s measured on an M4 Max)
        // and Core ML keeps the result, so the first session loads in about two seconds.
        let recognizer = try await WhisperRecognizer.load(model: model, verifiedFolder: { folder })
        try await recognizer.prewarm()
      },
      delete: { model in
        try installer.delete(model)
      }
    )
  }
}

extension RecognizerStore {
  /// The app's store: the bundled catalog, the default install root. A catalog that will
  /// not decode lists nothing rather than taking the app down; the catalog lint test is
  /// what keeps that from shipping.
  static func live(settings: AppSettings) -> RecognizerStore {
    let catalog = (try? Catalog.bundled()) ?? Catalog(schemaVersion: 1, catalogVersion: 0, models: [])
    return RecognizerStore(
      catalog: catalog,
      settings: settings,
      client: .live(installer: CatalogInstaller(catalogVersion: catalog.catalogVersion))
    )
  }
}
