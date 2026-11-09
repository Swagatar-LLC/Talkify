import Foundation
import Testing

@testable import Talkify

/// Pins the deterministic half of the shaping vocabulary eval, which runs in
/// CI while the model half cannot: what counts as a candidate, how accepted
/// spans land, and how an output is scored.
struct VocabularyCandidatesTests {
  private static let talkify = ShapingVocabularyCorpus.Entry(
    term: "Talkify", variants: ["Talk if I"], note: "an app", isOrdinaryWord: false
  )
  private static let wren = ShapingVocabularyCorpus.Entry(
    term: "Wren", variants: [], note: "a name", isOrdinaryWord: true
  )
  private static let tornike = ShapingVocabularyCorpus.Entry(
    term: "Tornike", variants: ["Torniquet"], note: "a person", isOrdinaryWord: false
  )

  @Test func aLearnedVariantOfAnUnusualTermIsProposedForDirectApply() throws {
    let found = VocabularyCandidates.find(
      in: "Did Talk if I paste that?", vocabulary: [Self.talkify]
    )
    let candidate = try #require(found.first)
    #expect(candidate.heard == "Talk if I")
    #expect(candidate.isLearnedVariant)
  }

  /// "let me talk if I may" differs from the learned "Talk if I" only in
  /// case, which is not proof enough to skip the judge.
  @Test func aVariantThatDiffersInCaseStillGoesToTheJudge() throws {
    let found = VocabularyCandidates.find(
      in: "Let me talk if I may.", vocabulary: [Self.talkify]
    )
    let candidate = try #require(found.first)
    #expect(!candidate.isLearnedVariant)
  }

  @Test func aTermAlreadySpelledRightIsNotACandidate() {
    #expect(VocabularyCandidates.find(in: "Talkify works.", vocabulary: [Self.talkify]).isEmpty)
  }

  @Test func aLowercaseOrdinaryWordMidSentenceIsLeftAlone() {
    #expect(VocabularyCandidates.find(in: "A small wren sang.", vocabulary: [Self.wren]).isEmpty)
  }

  @Test func aLowercaseOrdinaryWordStartingASentenceGoesToTheJudge() {
    #expect(VocabularyCandidates.find(in: "wren sang.", vocabulary: [Self.wren]).count == 1)
  }

  @Test func soundAlikeWordsWithFewSharedLettersAreNotCandidates() {
    #expect(VocabularyCandidates.find(in: "I think so.", vocabulary: [Self.tornike]).isEmpty)
  }

  @Test func acceptedSpansAreReplacedAndPunctuationSurvives() {
    let text = "Send Torniquet the note, and ask Talk if I."
    let found = VocabularyCandidates.find(in: text, vocabulary: [Self.talkify, Self.tornike])
    #expect(VocabularyCandidates.apply(found, to: text) == "Send Tornike the note, and ask Talkify.")
  }

  @Test func scoringCountsAFixAKeepAndAFalseCorrection() {
    let corpus = ShapingVocabularyCorpus(
      dictionary: [Self.talkify, Self.wren],
      cases: [
        .init(
          id: "t", kind: .term, voice: "", reference: "Talkify and Wren.",
          heard: "Talk if I and Wren."
        ),
        .init(id: "n", kind: .mustNotChange, voice: "", reference: "A wren.", heard: "A wren."),
      ]
    )
    let rows = [
      ShapingEvalRow(
        arm: "a", vocabularySize: 2, run: 0, caseID: "t",
        heard: "Talk if I and Wren.", output: "Talkify and Wren.", seconds: 0.5, error: nil
      ),
      ShapingEvalRow(
        arm: "a", vocabularySize: 2, run: 0, caseID: "n",
        heard: "A wren.", output: "A Wren.", seconds: nil, error: nil
      ),
    ]

    let score = ShapingEvalScoring.score(rows, corpus: corpus, vocabulary: corpus.dictionary)

    #expect(score.fixed == 1 && score.misheard == 1)
    #expect(score.kept == 1 && score.alreadyRight == 1)
    #expect(score.falseCorrections == 1 && score.mustNotChange == 1)
    #expect(score.latencies == [0.5])
  }

  @Test func capitalizingADictionaryWordThatOpensASentenceIsNotAFalseCorrection() {
    let count = { (text: String) in
      ShapingEvalScoring.occurrences(of: "Wren", in: text, countingSentenceStarts: false)
    }
    #expect(count("Wren built a nest. Wren left.") == 0)
    #expect(count("A Wren built a nest.") == 1)
    #expect(ShapingEvalScoring.occurrences(of: "Wren", in: "Wren left.") == 1)
  }
}
