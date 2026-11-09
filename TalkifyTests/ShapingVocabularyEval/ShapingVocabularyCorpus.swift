import Foundation

/// The shaping vocabulary eval's input: a user's vocabulary, and dictated
/// sentences as said and as the Speech Model heard them. Loaded from the JSON
/// beside this file, which `scripts/transcribe-shaping-eval-corpus.swift`
/// fills in.
struct ShapingVocabularyCorpus: Decodable, Sendable {
  struct Entry: Decodable, Equatable, Sendable {
    /// The exact spelling to insert.
    var term: String
    /// Forms the Speech Model wrote in place of the term before. The learn
    /// flow would collect these; here they come from a separate training set.
    var variants: [String]
    /// Context for the judge only. It is never inserted: in the design pass
    /// a free rewrite pasted notes into the text ("the VPN mesh network").
    var note: String
    /// The term is also a dictionary word ("pushover", "wren"), so a match
    /// on it is weak evidence and never applies without the judge.
    var isOrdinaryWord: Bool
  }

  struct Case: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
      /// The speaker said at least one vocabulary term.
      case term
      /// The speaker said no vocabulary term in the vocabulary's sense; many
      /// of these sound like one on purpose.
      case mustNotChange
    }

    var id: String
    var kind: Kind
    var voice: String
    var reference: String
    var heard: String
  }

  var dictionary: [Entry]
  var cases: [Case]

  static func load() throws -> Self {
    let url = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "shaping-vocabulary-corpus.json")
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }

  /// The real vocabulary padded with made-up terms up to `size`, to measure
  /// how a larger vocabulary costs time and precision. The padding is seeded,
  /// so every run and every machine sees the same vocabulary. Random syllable
  /// names are denser in sound-alikes than a real vocabulary would be, which
  /// makes the large sizes a pessimistic estimate.
  func vocabulary(size: Int) -> [Entry] {
    var entries = dictionary
    var generator = SplitMix64(seed: 7)
    var seen = Set(entries.map { $0.term.lowercased() })
    let onsets = ["k", "br", "v", "th", "z", "m", "l", "d", "sh", "r", "gr", "t", "n", "p", "fl", "ch", "s", "h", "j"]
    let nuclei = ["a", "e", "i", "o", "u", "ae", "ei", "ou", "y"]
    let codas = ["n", "r", "l", "x", "th", "sk", "nd", "rv", "lt", "m", "st", "z", "v", "ck", ""]
    let notes = ["a colleague", "a client", "a project codename", "a product", "a vendor", "a place"]
    while entries.count < size {
      let syllables = (0..<(generator.next() % 3 == 0 ? 3 : 2)).map { _ in
        onsets.randomElement(using: &generator)!
          + nuclei.randomElement(using: &generator)!
          + codas.randomElement(using: &generator)!
      }
      let term = syllables.joined().capitalized
      guard term.count >= 5, seen.insert(term.lowercased()).inserted else { continue }
      entries.append(
        Entry(
          term: term,
          variants: [syllables.joined(separator: " ")],
          note: notes.randomElement(using: &generator)!,
          isOrdinaryWord: false
        )
      )
    }
    return Array(entries.prefix(size))
  }
}

/// A seeded generator, because `SystemRandomNumberGenerator` cannot be seeded
/// and the padded vocabulary must be the same on every run.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
