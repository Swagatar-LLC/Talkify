import Foundation

/// The Vocabulary as Whisper reads it: one comma-separated line fed in as the initial
/// prompt, the text Whisper takes to have come just before the audio.
///
/// Whisper weights the end of its prompt most, and a long one hurts. In the spike a
/// 49-term list with the spoken terms first fell from 32 to 11 of 36 terms, and the same
/// list with them last scored 30, so the line keeps only the newest terms and ends on the
/// likeliest one.
enum WhisperPrompt {
  /// How many terms the line keeps.
  static let termLimit = 15

  /// The prompt line for `hints`, ordered likeliest last, or nil when there is none.
  ///
  /// Blank entries go, and a term given twice keeps only its later, likelier place.
  static func text(for hints: [String]) -> String? {
    var seen = Set<String>()
    var newestFirst: [String] = []
    for hint in hints.reversed() {
      let term = hint.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !term.isEmpty, seen.insert(term).inserted else { continue }
      newestFirst.append(term)
      if newestFirst.count == termLimit { break }
    }
    guard !newestFirst.isEmpty else { return nil }
    return newestFirst.reversed().joined(separator: ", ") + "."
  }
}
