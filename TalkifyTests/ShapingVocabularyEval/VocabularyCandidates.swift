import Foundation

/// One span of a transcript that looks like a vocabulary entry, proposed for
/// the judge to accept or reject.
struct VocabularyCandidate: Equatable, Sendable {
  var range: Range<String.Index>
  var heard: String
  var entry: ShapingVocabularyCorpus.Entry
  var score: Double
  /// The heard words are exactly a learned variant of an entry that is not a
  /// dictionary word, which is strong enough evidence to apply without the
  /// judge: "Torniquet" is never meant, "pushover" often is.
  var isLearnedVariant: Bool
}

/// The deterministic half of the Vocabulary pass the design pass recommends:
/// code proposes spans, the On-device model only says yes or no to each, and
/// code applies the accepted ones. The model never writes text, so it cannot
/// rewrite anything it was not asked about.
///
/// The thresholds are the design pass's, chosen on its own test set; this
/// corpus is held out from them, which is the point of measuring here.
enum VocabularyCandidates {
  /// More candidates than this and noise outvotes signal in the judge.
  static let limit = 8
  /// Plain letter similarity a span must reach, because a phonetic key alone
  /// matched "Turn" and "think" to Tornike.
  static let letterFloor = 0.5
  /// The better of letter and phonetic similarity a span must reach.
  static let threshold = 0.68

  static func find(
    in text: String,
    vocabulary: [ShapingVocabularyCorpus.Entry]
  ) -> [VocabularyCandidate] {
    let words = text.ranges(of: /[A-Za-z0-9']+/)
    var found: [VocabularyCandidate] = []
    for entry in vocabulary {
      let keys = ([entry.term] + entry.variants).map(letters).filter { $0.count >= 4 }
      var best: VocabularyCandidate?
      for length in 1...3 where length <= words.count {
        for start in 0...(words.count - length) {
          let range = words[start].lowerBound..<words[start + length - 1].upperBound
          let gram = letters(String(text[range]))
          var letterScore = 0.0
          var score = 0.0
          for key in keys where abs(gram.count - key.count) <= max(3, key.count / 2) {
            let letter = similarity(key, gram)
            let keyPhonetics = phoneticKey(key)
            let phonetic = keyPhonetics.count >= 3
              ? 0.95 * similarity(keyPhonetics, phoneticKey(gram)) : 0
            letterScore = max(letterScore, letter)
            score = max(score, letter, phonetic)
          }
          guard letterScore >= letterFloor, score >= threshold else { continue }
          if score > best?.score ?? 0 {
            let heard = String(text[range])
            best = VocabularyCandidate(
              range: range,
              heard: heard,
              entry: entry,
              score: score,
              isLearnedVariant: !entry.isOrdinaryWord && entry.variants.contains(heard)
            )
          }
        }
      }
      guard let best, best.heard != entry.term else { continue }
      // A capital letter is the only change, on a word the user also uses as
      // a word: mid-sentence, "a small wren" is far likelier than the name.
      if entry.isOrdinaryWord,
        best.heard.lowercased() == entry.term.lowercased(),
        !startsSentence(best.range, in: text)
      {
        continue
      }
      found.append(best)
    }

    var kept: [VocabularyCandidate] = []
    for candidate in found.sorted(by: { $0.score > $1.score })
    where !kept.contains(where: { $0.range.overlaps(candidate.range) }) {
      kept.append(candidate)
    }
    return Array(kept.prefix(limit))
  }

  /// Replaces each accepted span with its term and touches nothing else, so
  /// punctuation and spacing around a span survive as spoken.
  static func apply(_ accepted: [VocabularyCandidate], to text: String) -> String {
    var result = text
    for candidate in accepted.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
      result.replaceSubrange(candidate.range, with: candidate.entry.term)
    }
    return result
  }

  static func letters(_ text: String) -> String {
    String(text.lowercased().filter { $0.isASCII && $0.isLetter })
  }

  /// One minus the edit distance over the longer length.
  static func similarity(_ a: String, _ b: String) -> Double {
    let a = Array(a)
    let b = Array(b)
    guard !a.isEmpty || !b.isEmpty else { return 1 }
    var previous = Array(0...b.count)
    for (i, ca) in a.enumerated() {
      var current = [i + 1]
      for (j, cb) in b.enumerated() {
        current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
      }
      previous = current
    }
    return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
  }

  /// A crude sound key: fold letters that sound alike, keep the first letter,
  /// drop later vowels and repeats. Crude on purpose, it only has to rank
  /// spans for a judge that makes the real call.
  static func phoneticKey(_ text: String) -> String {
    var folded = letters(text)
    let folds = [
      ("ph", "f"), ("ck", "k"), ("q", "k"), ("x", "ks"), ("c", "k"), ("z", "s"),
      ("v", "f"), ("w", ""), ("g", "k"), ("d", "t"), ("b", "p"),
    ]
    for (from, to) in folds {
      folded = folded.replacingOccurrences(of: from, with: to)
    }
    guard let head = folded.first else { return "" }
    var key = String(head)
    for letter in folded.dropFirst() where !"aeiouyh".contains(letter) && letter != key.last {
      key.append(letter)
    }
    return key
  }

  private static func startsSentence(_ range: Range<String.Index>, in text: String) -> Bool {
    let before = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    guard let last = before.last else { return true }
    return ".!?".contains(last)
  }
}
