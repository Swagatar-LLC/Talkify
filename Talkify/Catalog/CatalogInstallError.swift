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
