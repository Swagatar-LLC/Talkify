/// Turns the Vocabulary into what each Recognizer is told to expect.
///
/// The input is the Vocabulary in its own order, newest last. Until learned
/// heard forms give it a ranking signal (ADR-9001), recency is the only one,
/// so that order is the ranking: likeliest last. Each Recognizer reads hints
/// differently, so each gets its own plan from the same list.
///
/// Pure: no framework, no tokenizer. Whisper's plan takes the token count as a
/// function, so the budget is checked with the model's own tokenizer at the
/// call site and with a stand-in in tests.
enum HintPlanner {
  /// Apple Speech's contextual strings: the Vocabulary exactly as given.
  ///
  /// Apple takes up to 100 phrases as a set, which is the Vocabulary's own
  /// ceiling, so nothing needs choosing.
  static func contextualStrings(for hints: [String]) -> [String] {
    hints
  }

  /// How many terms Whisper's prompt keeps. In the spike a 49-term prompt
  /// with the spoken terms first fell from 32 to 11 of 36; a short one does
  /// not have that cliff.
  static let whisperTermLimit = 15

  /// The most tokens Whisper's prompt may take, measured with the turbo
  /// model's tokenizer rather than counted in characters.
  ///
  /// The decoder holds 224 tokens, prompt and transcript together, and five
  /// go to fixed prefill (start-of-previous, start, language, task, no
  /// timestamps), leaving 218 to share. The corpus speaks at a median 4.18
  /// tokens a second, so a full 30 s window needs about 125 for its words,
  /// which leaves 93. WhisperKit cuts any prompt past 111 tokens from the
  /// front, mid-term, so 93 also keeps that cut from ever landing.
  static let whisperTokenBudget = 93

  /// Whisper's prompt line for `hints`, ordered likeliest last, or nil when
  /// there is none.
  ///
  /// Walks the hints from the likeliest down, keeping each term that still
  /// fits under `whisperTokenBudget` as measured by `tokenCount`, until
  /// `whisperTermLimit` are kept. A term too long to fit is skipped rather
  /// than ending the walk, so one pasted paragraph cannot push out the rest.
  /// Blank entries go, and a term given twice, in any casing, keeps only its
  /// later, likelier place.
  static func whisperPrompt(for hints: [String], tokenCount: (String) -> Int) -> String? {
    var seen = Set<String>()
    var kept: [String] = []
    for hint in hints.reversed() {
      guard kept.count < whisperTermLimit else { break }
      let term = trimmed(hint)
      guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
      let candidate = line([term] + kept)
      guard tokenCount(candidate) <= whisperTokenBudget else { continue }
      kept.insert(term, at: 0)
    }
    return kept.isEmpty ? nil : line(kept)
  }

  /// One comma-separated sentence, the shape Whisper reads as text that came
  /// just before the audio.
  private static func line(_ terms: [String]) -> String {
    terms.joined(separator: ", ") + "."
  }

  private static func trimmed(_ text: String) -> String {
    let start = text.firstIndex { !$0.isWhitespace } ?? text.endIndex
    let end = text.lastIndex { !$0.isWhitespace }.map(text.index(after:)) ?? start
    return String(text[start..<end])
  }
}
