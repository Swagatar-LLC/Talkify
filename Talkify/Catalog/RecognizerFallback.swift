import Foundation

/// Why a session that asked for a Catalog Model used Apple Speech instead.
///
/// Every case is shown in Settings and none is silent: the user chose a model, so a
/// session that did not use it says so and says why.
enum RecognizerFallback: Equatable, Sendable {
  /// A pinned file is missing, is not a regular file, or has the wrong size.
  case filesMissing
  /// A file is present at the right size but its bytes no longer match the catalog.
  case hashMismatch
  /// The catalog withdrew the model at `block` severity, with this reason.
  case revoked(String)
  /// The session's Dictation Language is not one the model is listed for, by its catalog tag.
  case unsupportedLanguage(String)
  /// The runtime refused the verified files, or ran out of memory loading them.
  case loadFailed(String)

  /// Sorts a failure from verifying or loading a model into the notice it earns. Anything
  /// that is not a file or catalog problem is reported as a load error, with its text.
  init(error: any Error) {
    switch error {
    case CatalogInstallError.missingFile, CatalogInstallError.notInstalled, CatalogInstallError.sizeMismatch:
      self = .filesMissing
    case CatalogInstallError.hashMismatch:
      self = .hashMismatch
    case CatalogInstallError.revoked(let reason):
      self = .revoked(reason)
    case WhisperRecognizer.Failure.unsupportedLanguage(let language):
      self = .unsupportedLanguage(language)
    case WhisperRecognizer.Failure.loadFailed(let reason):
      self = .loadFailed(reason)
    default:
      self = .loadFailed(error.localizedDescription)
    }
  }

  /// Whether downloading the model again could cure it.
  var offersRedownload: Bool {
    switch self {
    case .filesMissing, .hashMismatch: true
    case .revoked, .unsupportedLanguage, .loadFailed: false
    }
  }
}

/// A fallback, attached to the model the user had chosen, as Settings shows it.
struct RecognizerNotice: Equatable, Sendable {
  let modelID: String
  let modelName: String
  let fallback: RecognizerFallback

  var message: String {
    switch fallback {
    case .filesMissing:
      "\(modelName)'s files are missing or incomplete, so Apple Speech was used. "
        + "Download it again, or delete it."
    case .hashMismatch:
      "\(modelName)'s files no longer match the catalog, so Apple Speech was used. "
        + "Download it again, or delete it."
    case .revoked(let reason):
      "\(modelName) was withdrawn from the catalog (\(Self.clause(reason))), so Apple Speech was used."
    case .unsupportedLanguage(let language):
      "\(modelName) does not recognize \(Self.languageName(language)), "
        + "so Apple Speech was used for that session."
    case .loadFailed(let reason):
      "\(modelName) failed to load, so Apple Speech was used. \(reason)"
    }
  }

  /// A catalog reason without its closing full stop, to sit inside a sentence.
  private static func clause(_ reason: String) -> String {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
  }

  private static func languageName(_ tag: String) -> String {
    Locale.current.localizedString(forLanguageCode: tag) ?? tag
  }
}
