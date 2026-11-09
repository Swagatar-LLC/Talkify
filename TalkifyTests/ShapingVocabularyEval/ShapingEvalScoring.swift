import Foundation

/// What one arm wrote for one case on one run.
struct ShapingEvalRow: Codable, Sendable {
  var arm: String
  var vocabularySize: Int
  var run: Int
  var caseID: String
  var heard: String
  var output: String
  /// Wall-clock time of the model call, nil when the arm made none.
  var seconds: Double?
  var error: String?
}

/// The numbers an arm is judged by. Every term count is exact and
/// case-sensitive: "Chainbuilder" for ChainBuilder is still a misspelling.
struct ShapingEvalScore: Sendable {
  var arm: String
  var vocabularySize: Int
  var runs: Int
  /// Term occurrences the Speech Model got wrong, and how many came out right.
  var misheard = 0
  var fixed = 0
  /// Term occurrences the Speech Model got right, and how many survived.
  var alreadyRight = 0
  var kept = 0
  /// Must-not-change cases that gained a vocabulary term, out of all of them.
  var falseCorrections = 0
  var mustNotChange = 0
  /// Term cases that gained a vocabulary term the speaker did not say.
  var wrongTerms = 0
  var termCases = 0
  /// Must-not-change cases returned character for character as heard.
  var unchanged = 0
  var heardWordErrors = 0
  var outputWordErrors = 0
  var referenceWords = 0
  var latencies: [Double] = []
  var errors = 0
  var falseCorrectionExamples: [String] = []

  var correctionRate: Double { ratio(fixed, misheard) }
  var falseCorrectionRate: Double { ratio(falseCorrections, mustNotChange) }
  var heardWER: Double { ratio(heardWordErrors, referenceWords) }
  var outputWER: Double { ratio(outputWordErrors, referenceWords) }

  func percentile(_ fraction: Double) -> Double? {
    guard !latencies.isEmpty else { return nil }
    let sorted = latencies.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
  }

  private func ratio(_ part: Int, _ whole: Int) -> Double {
    whole == 0 ? 0 : Double(part) / Double(whole)
  }
}

enum ShapingEvalScoring {
  static func score(
    _ rows: [ShapingEvalRow],
    corpus: ShapingVocabularyCorpus,
    vocabulary: [ShapingVocabularyCorpus.Entry]
  ) -> ShapingEvalScore {
    let first = rows.first
    var score = ShapingEvalScore(
      arm: first?.arm ?? "",
      vocabularySize: first?.vocabularySize ?? 0,
      runs: Set(rows.map(\.run)).count
    )
    let cases = Dictionary(uniqueKeysWithValues: corpus.cases.map { ($0.id, $0) })
    let realTerms = corpus.dictionary.map(\.term)

    for row in rows {
      guard let item = cases[row.caseID] else { continue }
      for term in realTerms {
        let said = occurrences(of: term, in: item.reference)
        let heard = min(occurrences(of: term, in: row.heard), said)
        let out = min(occurrences(of: term, in: row.output), said)
        score.misheard += said - heard
        score.fixed += max(0, out - heard)
        score.alreadyRight += heard
        score.kept += min(out, heard)
      }
      // A capital on a dictionary word opening a sentence is grammar, not a
      // vocabulary insertion: "wren built a nest" → "Wren built a nest".
      let inserted = vocabulary.filter { entry in
        let count = { (text: String) in
          occurrences(of: entry.term, in: text, countingSentenceStarts: !entry.isOrdinaryWord)
        }
        let out = count(row.output)
        return out > count(item.reference) && out > count(row.heard)
      }
      switch item.kind {
      case .mustNotChange:
        score.mustNotChange += 1
        if row.output == row.heard { score.unchanged += 1 }
        if !inserted.isEmpty {
          score.falseCorrections += 1
          let example = "\(item.id): \(row.heard) → \(row.output)"
          if !score.falseCorrectionExamples.contains(example) {
            score.falseCorrectionExamples.append(example)
          }
        }
      case .term:
        score.termCases += 1
        if !inserted.isEmpty { score.wrongTerms += 1 }
      }
      let reference = words(item.reference)
      score.referenceWords += reference.count
      score.heardWordErrors += editDistance(reference, words(row.heard))
      score.outputWordErrors += editDistance(reference, words(row.output))
      if let seconds = row.seconds { score.latencies.append(seconds) }
      if row.error != nil { score.errors += 1 }
    }
    return score
  }

  /// Whole-word, case-sensitive matches, so "Wren" is not found in "wrench"
  /// and "wren" is not "Wren".
  static func occurrences(
    of term: String,
    in text: String,
    countingSentenceStarts: Bool = true
  ) -> Int {
    let opening = countingSentenceStarts ? "" : "(?<=.)(?<![.!?]\\s)"
    let pattern = opening + "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: term)
      + "(?![A-Za-z0-9])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
    return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
  }

  /// Lowercased words without punctuation: word error rate measures words,
  /// and the spelling metrics above already hold case to account.
  static func words(_ text: String) -> [String] {
    text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
  }

  static func editDistance(_ a: [String], _ b: [String]) -> Int {
    var previous = Array(0...b.count)
    for (i, wa) in a.enumerated() {
      var current = [i + 1]
      for (j, wb) in b.enumerated() {
        current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (wa == wb ? 0 : 1)))
      }
      previous = current
    }
    return previous[b.count]
  }

  static func markdownTable(_ scores: [ShapingEvalScore]) -> String {
    func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
    func milliseconds(_ value: Double?) -> String {
      value.map { String(format: "%.0f", $0 * 1000) } ?? "–"
    }
    var lines = [
      "| arm | vocabulary | runs | corrected | kept | false corrections | wrong term in term case | unchanged must-not-change | WER heard → out | model calls | p50 ms | p95 ms | errors |",
      "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for score in scores {
      lines.append(
        "| \(score.arm) | \(score.vocabularySize) | \(score.runs) "
          + "| \(percent(score.correctionRate)) (\(score.fixed)/\(score.misheard)) "
          + "| \(score.kept)/\(score.alreadyRight) "
          + "| \(percent(score.falseCorrectionRate)) (\(score.falseCorrections)/\(score.mustNotChange)) "
          + "| \(score.wrongTerms)/\(score.termCases) "
          + "| \(score.unchanged)/\(score.mustNotChange) "
          + "| \(String(format: "%.3f → %.3f", score.heardWER, score.outputWER)) "
          + "| \(score.latencies.count) | \(milliseconds(score.percentile(0.5))) "
          + "| \(milliseconds(score.percentile(0.95))) | \(score.errors) |"
      )
    }
    return lines.joined(separator: "\n")
  }
}
