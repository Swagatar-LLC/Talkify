import Foundation
import Testing
import os

@testable import Talkify

/// Measures how well the On-device model gets a user's vocabulary right after
/// the Speech Model got it wrong, and how often it puts a vocabulary term
/// where none was said. Calls the real model, so it is off by default: it
/// needs Apple Intelligence and takes minutes.
///
///   TEST_RUNNER_TALKIFY_SHAPING_EVAL=/path/to/out xcodebuild test \
///     -project Talkify.xcodeproj -scheme Talkify -destination 'platform=macOS' \
///     -only-testing:TalkifyTests/ShapingVocabularyEvalTests
///
/// xcodebuild hands the test process only variables carrying the
/// TEST_RUNNER_ prefix, and strips it. Optional: TALKIFY_SHAPING_EVAL_RUNS
/// (default 1) repeats every model arm, because sampling is not greedy;
/// TALKIFY_SHAPING_EVAL_SIZES (default 14,50,200) lists the vocabulary
/// sizes. xcodebuild swallows the test's stdout, so the results land in the
/// output folder: summary.md and rows.json, with progress.log growing while
/// it runs.
///
/// Arms:
/// - heard: the Speech Model's text, untouched. The baseline.
/// - shaping: the Tighten grammar seed, no vocabulary.
/// - shaping+vocabulary: the same prompt with the vocabulary listed in its
///   pre-instruction, the way a user would add one today.
/// - vocabulary pass: candidates in code, learned variants applied directly,
///   a yes/no judge for the rest, code applies what it accepts.
/// - vocabulary pass, judge all: the same, with learned variants judged too.
/// - vocabulary pass→shaping: the pass, then Tighten grammar told to keep the
///   pass's spellings, falling back to the pass's text if shaping drops one.
@Suite(
  "Shaping vocabulary eval",
  .enabled(if: ProcessInfo.processInfo.environment["TALKIFY_SHAPING_EVAL"] != nil)
)
struct ShapingVocabularyEvalTests {
  @Test func measureEveryArm() async throws {
    let environment = ProcessInfo.processInfo.environment
    let output = URL(filePath: try #require(environment["TALKIFY_SHAPING_EVAL"]))
    let runs = environment["TALKIFY_SHAPING_EVAL_RUNS"].flatMap(Int.init) ?? 1
    let sizes = environment["TALKIFY_SHAPING_EVAL_SIZES"]?
      .split(separator: ",").compactMap { Int($0) } ?? [14, 50, 200]
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let log = ProgressLog(url: output.appending(path: "progress.log"))

    let corpus = try ShapingVocabularyCorpus.load()
    try #require(corpus.cases.allSatisfy { !$0.heard.isEmpty }, "run the transcription script first")
    let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
    let live = PromptShapingService.Client.live
    try #require(live.unavailabilityReason() == nil, "the On-device model is not available")
    // The live client, recording why a rewrite failed: the service turns every
    // failure into passthrough, which the eval must count, not hide.
    let shaping = PromptShapingService(
      client: PromptShapingService.Client(
        unavailabilityReason: live.unavailabilityReason,
        respond: { instructions, prompt in
          do {
            return try await live.respond(instructions, prompt)
          } catch {
            failure.withLock { $0 = String(describing: error) }
            throw error
          }
        }
      )
    )
    let grammar = ShapingPrompt.defaults[0]
    let clock = ContinuousClock()

    func shape(_ text: String, with prompt: ShapingPrompt) async -> (String, Double, String?) {
      failure.withLock { $0 = nil }
      var shaped = ""
      let elapsed = await clock.measure { shaped = await shaping.shape(text, with: prompt) }
      return (shaped, elapsed.seconds, failure.withLock { $0 })
    }

    var rows: [ShapingEvalRow] = corpus.cases.map {
      ShapingEvalRow(
        arm: "heard", vocabularySize: 0, run: 0, caseID: $0.id,
        heard: $0.heard, output: $0.heard, seconds: nil, error: nil
      )
    }

    for run in 0..<runs {
      for item in corpus.cases {
        let (shaped, seconds, error) = await shape(item.heard, with: grammar)
        rows.append(
          ShapingEvalRow(
            arm: "shaping", vocabularySize: 0, run: run, caseID: item.id,
            heard: item.heard, output: shaped, seconds: seconds, error: error
          )
        )
      }
      log.write("run \(run) shaping done")

      func vocabularyPass(_ arm: String, size: Int, trustLearnedVariants: Bool) async {
        let vocabulary = corpus.vocabulary(size: size)
        for item in corpus.cases {
          var pass = VocabularyPassOutcome(text: "", accepted: [], askedModel: false)
          let elapsed = await clock.measure {
            pass = await VocabularyPass.run(
              item.heard, vocabulary: vocabulary, trustLearnedVariants: trustLearnedVariants
            )
          }
          rows.append(
            ShapingEvalRow(
              arm: arm, vocabularySize: size, run: run, caseID: item.id,
              heard: item.heard, output: pass.text,
              seconds: pass.askedModel ? elapsed.seconds : nil, error: pass.error
            )
          )
        }
        log.write("run \(run) \(arm) \(size) done")
      }

      for size in sizes {
        // The only place a user can put a vocabulary today is a Shaping
        // Prompt's own wording, so that is where this arm puts it.
        var listed = grammar
        listed.preInstruction += " Spell these names exactly as written here when "
          + "the transcript means one of them: "
          + corpus.vocabulary(size: size).map(\.term).joined(separator: ", ") + "."
        for item in corpus.cases {
          let (shaped, seconds, error) = await shape(item.heard, with: listed)
          rows.append(
            ShapingEvalRow(
              arm: "shaping+vocabulary", vocabularySize: size, run: run, caseID: item.id,
              heard: item.heard, output: shaped, seconds: seconds, error: error
            )
          )
        }
        log.write("run \(run) shaping+vocabulary \(size) done")

        await vocabularyPass("vocabulary pass", size: size, trustLearnedVariants: true)
      }

      let size = sizes.first ?? corpus.dictionary.count
      await vocabularyPass("vocabulary pass, judge all", size: size, trustLearnedVariants: false)

      let vocabulary = corpus.vocabulary(size: size)
      for item in corpus.cases {
        let start = clock.now
        let pass = await VocabularyPass.run(item.heard, vocabulary: vocabulary)
        let protected = vocabulary.map(\.term).filter {
          ShapingEvalScoring.occurrences(of: $0, in: pass.text) > 0
        }
        var prompt = grammar
        if !protected.isEmpty {
          prompt.preInstruction += " Keep these spellings exactly: "
            + protected.joined(separator: ", ") + "."
        }
        let (shaped, _, shapingError) = await shape(pass.text, with: prompt)
        let survived = protected.allSatisfy {
          ShapingEvalScoring.occurrences(of: $0, in: shaped)
            >= ShapingEvalScoring.occurrences(of: $0, in: pass.text)
        }
        rows.append(
          ShapingEvalRow(
            arm: "vocabulary pass→shaping", vocabularySize: vocabulary.count, run: run,
            caseID: item.id, heard: item.heard, output: survived ? shaped : pass.text,
            seconds: (clock.now - start).seconds, error: pass.error ?? shapingError
          )
        )
      }
      log.write("run \(run) vocabulary pass→shaping done")
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(rows).write(to: output.appending(path: "rows.json"))

    var groups: [(arm: String, size: Int)] = []
    for row in rows where !groups.contains(where: { $0 == (row.arm, row.vocabularySize) }) {
      groups.append((row.arm, row.vocabularySize))
    }
    let scores = groups.map { group in
      ShapingEvalScoring.score(
        rows.filter { $0.arm == group.arm && $0.vocabularySize == group.size },
        corpus: corpus,
        vocabulary: corpus.vocabulary(size: max(group.size, corpus.dictionary.count))
      )
    }
    var summary = [
      "# Shaping vocabulary eval",
      "",
      "\(corpus.cases.count) cases, \(runs) run(s) per model arm, vocabulary sizes \(sizes).",
      "",
      ShapingEvalScoring.markdownTable(scores),
      "",
      "## False corrections",
    ]
    for score in scores where !score.falseCorrectionExamples.isEmpty {
      summary.append("")
      summary.append("\(score.arm) (\(score.vocabularySize)):")
      summary += score.falseCorrectionExamples.map { "- \($0)" }
    }
    try summary.joined(separator: "\n").appending("\n")
      .write(to: output.appending(path: "summary.md"), atomically: true, encoding: .utf8)
    log.write("done")

    #expect(rows.count > corpus.cases.count)
  }
}

private extension Duration {
  var seconds: Double {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}

/// Appends a line per finished arm, so a run that takes minutes can be
/// watched from outside the test process.
private struct ProgressLog {
  let url: URL

  init(url: URL) {
    self.url = url
    FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
  }

  func write(_ line: String) {
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    handle.seekToEndOfFile()
    handle.write(Data("\(Date.now.ISO8601Format()) \(line)\n".utf8))
    try? handle.close()
  }
}
