import Foundation

extension CatalogModel {
  /// The folder under the install root that WhisperKit loads: the one holding
  /// `tokenizer.json` beside the Core ML models. Nil when the entry has no such file.
  var whisperModelPath: String? {
    guard let tokenizerPath = installPaths.first(where: { ($0 as NSString).lastPathComponent == "tokenizer.json" })
    else { return nil }
    let folder = (tokenizerPath as NSString).deletingLastPathComponent
    return folder.isEmpty ? "." : folder
  }
}
