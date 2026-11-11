import Foundation

/// Why a Catalog Model would not install or load. Every case leaves no partial model behind.
enum CatalogInstallError: Error, Equatable, Sendable {
  /// The entry is revoked at `block` severity: never fetched, never loaded.
  case revoked(String)
  case insufficientSpace(needed: Int64, available: Int64)
  case httpStatus(path: String, status: Int)
  /// A redirect pointed off the allowlist or away from HTTPS. `nil` when it had no URL.
  case redirectRefused(URL?)
  /// The host sent more bytes than the catalog pins for this file.
  case fileTooLarge(path: String, limit: Int64)
  /// The host sent more bytes, across every file, than the entry's `totalBytes`.
  case modelTooLarge(limit: Int64)
  case sizeMismatch(path: String, expected: Int64, actual: Int64)
  case hashMismatch(path: String)
  /// A pinned file is missing, is not a regular file, or resolves outside the model folder.
  case missingFile(path: String)
  case notInstalled
}

extension CatalogInstallError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .revoked(let reason):
      "This model was withdrawn from the catalog: \(reason)"
    case .insufficientSpace(let needed, let available):
      "Not enough free space: the download needs "
        + "\(Self.size(needed)) and this Mac has \(Self.size(available))."
    case .httpStatus(_, let status):
      "The download host answered with HTTP \(status)."
    case .redirectRefused:
      "The download host redirected somewhere Talkify does not download from."
    case .fileTooLarge, .modelTooLarge, .sizeMismatch:
      "A downloaded file was not the size the catalog pins. Nothing was kept."
    case .hashMismatch:
      "A downloaded file did not match the catalog's fingerprint. Nothing was kept."
    case .missingFile:
      "A model file is missing or incomplete."
    case .notInstalled:
      "This model is not downloaded."
    }
  }

  private static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
