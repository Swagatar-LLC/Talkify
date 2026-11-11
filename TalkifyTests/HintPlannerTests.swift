import Testing

@testable import Talkify

struct HintPlannerTests {
  /// The spike's 49-term Vocabulary: 40 glossary terms never spoken in the corpus,
  /// then the nine that are, so the likeliest come last.
  private let spikeVocabulary = [
    "Kubernetes", "Grafana", "Postgres", "Tailscale", "Pushover", "Mnemosyne", "Hermes",
    "Sparkle", "FluidAudio", "WhisperKit", "Notion", "Todoist", "Obsidian", "reMarkable",
    "Raindrop", "YouVersion", "Jira", "Confluence", "Discord", "Telegram", "Pebble", "Chuy",
    "Sam", "Index01", "Hindsight", "Codex", "Anthropic", "Nous", "Argmax", "Moonshine",
    "Granite", "Parakeet", "SpeechAnalyzer", "Xcode", "Swift", "Metal", "AppKit", "SwiftUI",
    "Sendable", "Gomareli", "Talkify", "Swagatar", "Hampton", "Wren", "Hedy", "Erin",
    "Stephen", "Vorno", "ChainBuilder",
  ]

  /// A stand-in tokenizer: one token per character, so budgets are easy to reason about.
  private let perCharacter: (String) -> Int = { $0.count }
  private let free: (String) -> Int = { _ in 0 }

  private func terms(_ prompt: String?) throws -> [String] {
    try #require(prompt).dropLast().split(separator: ", ").map(String.init)
  }

  @Test func appleGetsTheVocabularyExactlyAsGiven() {
    #expect(HintPlanner.contextualStrings(for: spikeVocabulary) == spikeVocabulary)
    #expect(HintPlanner.contextualStrings(for: []) == [])
    let untidy = ["Wren", " Wren ", "", "wren", String(repeating: "x", count: 200)]
    #expect(HintPlanner.contextualStrings(for: untidy) == untidy)
  }

  @Test func noHintsMeansNoPrompt() {
    #expect(HintPlanner.whisperPrompt(for: [], tokenCount: free) == nil)
    #expect(HintPlanner.whisperPrompt(for: ["", "  ", "\n"], tokenCount: free) == nil)
  }

  @Test func termsJoinInTheOrderGivenAndEndTheLine() {
    #expect(HintPlanner.whisperPrompt(for: ["Talkify", "Wren", "Vorno"], tokenCount: free) == "Talkify, Wren, Vorno.")
  }

  @Test func aLongListKeepsTheNewestFifteenWithTheLikeliestLast() throws {
    let kept = try terms(HintPlanner.whisperPrompt(for: (1...40).map { "term\($0)" }, tokenCount: free))
    #expect(kept == (26...40).map { "term\($0)" })
    #expect(HintPlanner.whisperTermLimit == 15)
  }

  @Test func theSpikeVocabularyKeepsItsSpokenTermsAndSixGlossaryTermsBeforeThem() throws {
    let kept = try terms(HintPlanner.whisperPrompt(for: spikeVocabulary, tokenCount: free))
    #expect(kept == Array(spikeVocabulary.suffix(15)))
    #expect(kept.last == "ChainBuilder")
  }

  @Test func aRepeatedTermKeepsItsLaterPlaceInAnyCasing() {
    #expect(HintPlanner.whisperPrompt(for: ["Wren", "Vorno", " Wren "], tokenCount: free) == "Vorno, Wren.")
    #expect(HintPlanner.whisperPrompt(for: ["Wren", "Vorno", "WREN"], tokenCount: free) == "Vorno, WREN.")
  }

  @Test func repeatsDoNotTakeSlotsFromOtherTerms() throws {
    let hints = (1...15).map { "term\($0)" } + Array(repeating: "term15", count: 10)
    let kept = try terms(HintPlanner.whisperPrompt(for: hints, tokenCount: free))
    #expect(kept.count == 15)
    #expect(kept.first == "term1")
  }

  @Test func theBudgetDropsTheLeastLikelyTermsFirst() throws {
    // Ten-character terms: n of them make a line of 12n - 1 characters, so seven fit in 93.
    let hints = (10...29).map { "abcdefgh\($0)" }
    let prompt = try #require(HintPlanner.whisperPrompt(for: hints, tokenCount: perCharacter))
    #expect(try terms(prompt) == (23...29).map { "abcdefgh\($0)" })
    #expect(prompt.count <= HintPlanner.whisperTokenBudget)
  }

  @Test func aTermTooLongToFitIsSkippedAndOlderTermsStillFill() {
    let long = String(repeating: "x", count: HintPlanner.whisperTokenBudget)
    #expect(HintPlanner.whisperPrompt(for: ["Hedy", "Erin", long, "Wren"], tokenCount: perCharacter) == "Hedy, Erin, Wren.")
    #expect(HintPlanner.whisperPrompt(for: [long], tokenCount: perCharacter) == nil)
  }

  @Test func aPromptExactlyAtTheBudgetIsKept() {
    // One term plus its full stop, exactly the budget.
    let term = String(repeating: "y", count: HintPlanner.whisperTokenBudget - 1)
    #expect(HintPlanner.whisperPrompt(for: [term], tokenCount: perCharacter) == term + ".")
  }

  @Test func everyPlannedPromptStaysWithinTheBudget() {
    // Term lengths cycling 1 to 64, the Vocabulary's own limit, across full 100-term lists.
    for offset in 0..<64 {
      let hints = (0..<Vocabulary.maximumTermCount).map {
        String(repeating: "z", count: ($0 + offset) % Vocabulary.maximumTermLength + 1) + "\($0)"
      }
      let prompt = HintPlanner.whisperPrompt(for: hints, tokenCount: perCharacter)
      #expect((prompt?.count ?? 0) <= HintPlanner.whisperTokenBudget)
    }
  }

  @Test func theSameVocabularyAlwaysPlansTheSamePrompt() {
    let hints = spikeVocabulary + ["wren", "Kubernetes"]
    let first = HintPlanner.whisperPrompt(for: hints, tokenCount: perCharacter)
    for _ in 0..<10 {
      #expect(HintPlanner.whisperPrompt(for: hints, tokenCount: perCharacter) == first)
    }
  }
}
