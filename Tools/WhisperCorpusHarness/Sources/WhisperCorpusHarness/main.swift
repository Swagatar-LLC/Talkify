import AVFAudio
import Foundation
import os

// Runs the hint-spike corpus through the Whisper Recognizer the way a session would: the
// catalog entry verified by the installer's re-hash, the corpus terms set as hints, each clip
// fed in 100 ms buffers and finished. Reports term hits, controls kept, WER, finish latency,
// load time and memory, and checks the slice 4 gate. Exit status: 0 gate passed, 1 gate
// failed, 2 the run could not complete.
//
// usage: WhisperCorpusHarness <whisperkit fixtures> <corpus folder> <out folder>
//          [--nospeech <folder>] [--short <folder>] [--hints <file>] [--min-terms <n>]
//          [--expect-network-denied]
//
// The hints are the corpus terms in the order they first occur, unless --hints names a file
// of terms, one per line, likeliest last.
// <whisperkit fixtures> holds openai_whisper-large-v3-v20240930_turbo_632MB/; <corpus folder>
// holds corpus.json and wav/. The install root is <out folder>/models, kept between runs so
// Core ML's compile cache stays valid; its files are hard links to the fixtures, laid out
// where the installer puts them, so the installer's own check verifies every byte.

struct Clip: Codable {
  var file: String
  var text: String
  var analysisMs: Double
  var audioSec: Double
  var setupMs: Double
}

struct HarnessError: Error, CustomStringConvertible {
  var description: String
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else { fail("usage: WhisperCorpusHarness <fixtures> <corpus> <out> [--nospeech dir] [--short dir] [--hints file] [--min-terms n] [--expect-network-denied]") }
let fixtures = URL(filePath: arguments[1], directoryHint: .isDirectory)
let corpusFolder = URL(filePath: arguments[2], directoryHint: .isDirectory)
let out = URL(filePath: arguments[3], directoryHint: .isDirectory)
func option(_ name: String) -> String? {
  arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}
let expectNetworkDenied = arguments.contains("--expect-network-denied")

/// One session: start, feed the clip in 100 ms buffers, then time `finish`.
func session(_ recognizer: WhisperRecognizer, samples: [Float], clock: ContinuousClock) async throws -> (String, Duration) {
  let format = WhisperRecognizer.format
  try await recognizer.start(locale: Locale(identifier: "en_US"), updateHandler: { _ in }) { asked in
    guard asked == format else { throw HarnessError(description: "the recognizer asked for \(asked)") }
  }
  for start in stride(from: 0, to: samples.count, by: 1_600) {
    let count = min(1_600, samples.count - start)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
      throw HarnessError(description: "no buffer")
    }
    buffer.frameLength = AVAudioFrameCount(count)
    samples.withUnsafeBufferPointer { source in
      buffer.floatChannelData![0].update(from: source.baseAddress! + start, count: count)
    }
    guard recognizer.feed(buffer) else { throw HarnessError(description: "a buffer was dropped") }
  }
  let finishStart = clock.now
  let text = try await recognizer.finish()
  return (text, clock.now - finishStart)
}

func readSamples(_ url: URL) throws -> [Float] {
  let file = try AVAudioFile(forReading: url)
  let format = file.processingFormat
  guard format.sampleRate == WhisperRecognizer.sampleRate, format.channelCount == 1,
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
  else { throw HarnessError(description: "\(url.lastPathComponent) is not 16 kHz mono") }
  try file.read(into: buffer)
  return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func wavs(in folder: URL) throws -> [URL] {
  try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "wav" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Lays the fixtures out where the installer puts a finished install, as hard links.
func stage(_ model: CatalogModel, for installer: CatalogInstaller) throws {
  let folder = installer.installFolder(for: model)
  for path in model.installPaths {
    let destination = folder.appending(path: path)
    guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.linkItem(at: fixtures.appending(path: path), to: destination)
  }
}

func run() async throws -> Bool {
  try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  var report: [String: Any] = [:]
  var lines: [String] = []
  let clock = ContinuousClock()

  let network = NetworkProbe.attempt()
  report["networkProbe"] = network
  lines.append("network probe (TCP connect to 1.1.1.1:443 from this process): \(network)")
  if expectNetworkDenied, !network.contains("Operation not permitted") {
    throw HarnessError(description: "this run was meant to be sandboxed, but the probe says: \(network)")
  }
  let baseline = Memory.sample()

  let catalog = try Catalog(data: Data(contentsOf: URL(filePath: #filePath)
    .deletingLastPathComponent().appending(path: "Talkify/Catalog/catalog.json")))
  guard let model = catalog.models.first(where: { $0.runtime.id == WhisperRecognizer.runtimeID }) else {
    throw HarnessError(description: "no Whisper entry in the catalog")
  }
  let installer = CatalogInstaller(
    root: out.appending(path: "models", directoryHint: .isDirectory),
    compiledModelCache: nil,
    catalogVersion: catalog.catalogVersion)
  try stage(model, for: installer)

  let rehashStart = clock.now
  _ = try installer.verifiedFolder(for: model)
  let rehash = clock.now - rehashStart
  let rehashed = Memory.sample()

  let loadStart = clock.now
  let recognizer = try await WhisperRecognizer.load(model: model) { try installer.verifiedFolder(for: model) }
  let load = clock.now - loadStart
  let loaded = Memory.sample()
  let prewarmStart = clock.now
  try await recognizer.prewarm()
  let prewarm = clock.now - prewarmStart
  let warmed = Memory.sample()

  let corpus = try JSONDecoder().decode(
    [CorpusScore.Sentence].self, from: Data(contentsOf: corpusFolder.appending(path: "corpus.json")))
  var hints: [String] = []
  if let hintsFile = option("--hints") {
    hints = try String(contentsOf: URL(filePath: hintsFile), encoding: .utf8)
      .split(whereSeparator: \.isNewline).map(String.init)
  } else {
    for sentence in corpus { for term in sentence.targets where !hints.contains(term) { hints.append(term) } }
  }
  await recognizer.setHints(hints)
  let plannedPrompt = await recognizer.prompt ?? ""
  let plannedTokens = await recognizer.promptTokens?.count ?? 0
  report["prompt"] = plannedPrompt
  report["promptTokens"] = plannedTokens
  lines.append("planned prompt (\(plannedTokens) tokens, budget \(HintPlanner.whisperTokenBudget)): \(plannedPrompt)")

  let corpusWavs = try wavs(in: corpusFolder.appending(path: "wav", directoryHint: .isDirectory))
  guard corpusWavs.count == 48 else { throw HarnessError(description: "expected 48 corpus clips, found \(corpusWavs.count)") }
  var clips: [Clip] = []
  var warmPeak = warmed
  for wav in corpusWavs {
    let samples = try readSamples(wav)
    let (text, finish) = try await session(recognizer, samples: samples, clock: clock)
    clips.append(Clip(
      file: wav.lastPathComponent, text: text, analysisMs: finish.milliseconds,
      audioSec: Double(samples.count) / WhisperRecognizer.sampleRate, setupMs: load.milliseconds))
    warmPeak = warmPeak.max(Memory.sample())
  }

  var silenceTexts: [String: String] = [:]
  silenceTexts["generated 3 s of zeros"] = try await session(
    recognizer, samples: [Float](repeating: 0, count: 48_000), clock: clock).0
  if let noSpeech = option("--nospeech") {
    for wav in try wavs(in: URL(filePath: noSpeech, directoryHint: .isDirectory)) {
      silenceTexts[wav.lastPathComponent] = try await session(recognizer, samples: readSamples(wav), clock: clock).0
    }
  }
  let silenceEmpty = silenceTexts.filter { $0.key.contains("silence") || $0.key.contains("zeros") }.allSatisfy(\.value.isEmpty)
  lines.append("silence and noise: " + silenceTexts.sorted { $0.key < $1.key }.map { "\($0.key) -> \"\($0.value)\"" }.joined(separator: "; "))
  report["silence"] = silenceTexts

  if let short = option("--short") {
    var shortTexts: [String: String] = [:]
    for wav in try wavs(in: URL(filePath: short, directoryHint: .isDirectory)) {
      shortTexts[wav.lastPathComponent] = try await session(recognizer, samples: readSamples(wav), clock: clock).0
    }
    lines.append("short sessions: " + shortTexts.sorted { $0.key < $1.key }.map { "\($0.key) -> \"\($0.value)\"" }.joined(separator: "; "))
    report["shortSessions"] = shortTexts
  }
  let afterCorpus = Memory.sample()

  // Longer than Whisper's 30 s window: all sixteen sentences in one voice, with a short
  // pause between, must come back whole.
  let longClips = corpusWavs.filter { $0.lastPathComponent.contains("_alex") }
  var longSamples: [Float] = []
  var longReference = ""
  for wav in longClips {
    longSamples += try readSamples(wav) + [Float](repeating: 0, count: 4_800)
    longReference += (corpus.first { $0.id == String(wav.lastPathComponent.prefix(3)) }?.text ?? "") + " "
  }
  let (longText, longFinish) = try await session(recognizer, samples: longSamples, clock: clock)
  let longWords = CorpusScore.words(longReference)
  let longWER = 100 * Double(CorpusScore.editDistance(longWords, CorpusScore.words(longText))) / Double(longWords.count)
  lines.append(String(
    format: "long session: %d clips, %.1f s of audio, WER %.1f %%, finish %.0f ms; text: %@",
    longClips.count, Double(longSamples.count) / WhisperRecognizer.sampleRate, longWER, longFinish.milliseconds, longText))
  report["longSession"] = [
    "clips": longClips.count, "audioSeconds": Double(longSamples.count) / WhisperRecognizer.sampleRate,
    "werPercent": longWER, "finishMs": longFinish.milliseconds, "text": longText,
  ]

  // A language the entry is not listed for is refused at start, before any capture.
  let captureBegan = OSAllocatedUnfairLock(initialState: false)
  var unsupported: String
  do {
    try await recognizer.start(locale: Locale(identifier: "de_DE"), updateHandler: { _ in }) { _ in
      captureBegan.withLock { $0 = true }
    }
    await recognizer.cancel()
    unsupported = "accepted"
  } catch {
    unsupported = "refused: \(error.localizedDescription)"
  }
  if captureBegan.withLock({ $0 }) { unsupported += " (capture began)" }
  lines.append("de_DE session: \(unsupported)")

  // The budget against the real tokenizer: Vocabularies whose terms tokenize badly, each as
  // long as the Vocabulary allows. Every planned prompt must stay within the budget.
  var budgetProbe: [String: Int] = [:]
  let probes: [String: [String]] = [
    "64 x Latin letter": (0..<100).map { String(repeating: "x", count: 63) + "\($0 % 10)" },
    "64 x CJK": (0..<100).map { String(repeating: "語", count: 63) + "\($0 % 10)" },
    "64 x emoji": (0..<100).map { String(repeating: "🪶", count: 63) + "\($0 % 10)" },
  ]
  for (name, probe) in probes {
    await recognizer.setHints(probe)
    budgetProbe[name] = await recognizer.promptTokens?.count ?? 0
  }
  let budgetHeld = budgetProbe.values.allSatisfy { $0 <= HintPlanner.whisperTokenBudget }
  lines.append("budget probe, tokens: " + budgetProbe.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "; "))
  report["budgetProbeTokens"] = budgetProbe

  let end = Memory.sample()
  let score = CorpusScore(corpus: corpus).score(clips.map { ($0.file, $0.text) })
  let latencies = clips.map(\.analysisMs).sorted()
  let p50 = CorpusScore.median(latencies)
  let p90 = latencies[Int(0.9 * Double(latencies.count - 1))]

  let jsonl = try clips.map { String(decoding: try JSONEncoder.sorted.encode($0), as: UTF8.self) }.joined(separator: "\n")
  try (jsonl + "\n").write(to: out.appending(path: "whisper_turbo_recognizer.jsonl"), atomically: true, encoding: .utf8)

  // Slice 4 pinned the 9-term run at 32 ± 2; --min-terms sets a floor instead.
  let termsGate = option("--min-terms").flatMap(Int.init).map {
    ("terms >= \($0)/36", score.targetHits >= $0)
  } ?? ("terms 32/36 ± 2", abs(score.targetHits - 32) <= 2)
  let gate: [String: Bool] = [
    termsGate.0: termsGate.1,
    "controls 18/18 unchanged (unit-normalised)": score.protectedUnitNorm == score.protectedTotal,
    "empty output on silence": silenceEmpty,
    "p90 finish latency <= 1.0 s": p90 <= 1000,
    "warm RSS <= 400 MiB": warmPeak.residentMiB <= 400,
    "prompt within the token budget": budgetHeld && plannedTokens <= HintPlanner.whisperTokenBudget,
  ]
  report.merge([
    "model": model.id, "files": clips.count, "hints": hints,
    "termHits": score.targetHits, "terms": score.targetTotal, "termsCaseless": score.targetHitsCaseless,
    "controlsStrict": score.protectedStrict, "controlsUnitNorm": score.protectedUnitNorm,
    "controls": score.protectedTotal, "werPercent": score.werPercent, "perTerm": score.perTerm,
    "finishMsP50": p50, "finishMsP90": p90, "finishMsMax": latencies.last ?? 0,
    "rehashSeconds": rehash.seconds, "coldLoadSeconds": load.seconds, "prewarmSeconds": prewarm.seconds,
    "residentMiB": [
      "baseline": baseline.residentMiB, "afterLoad": loaded.residentMiB, "afterPrewarm": warmed.residentMiB,
      "warmPeakSampled": warmPeak.residentMiB, "processPeak": end.residentPeakMiB,
    ],
    "footprintMiB": [
      "baseline": baseline.footprintMiB, "afterLoad": loaded.footprintMiB,
      "warmPeakSampled": warmPeak.footprintMiB, "processPeak": end.footprintPeakMiB,
    ],
    "unsupportedLanguage": unsupported, "gate": gate,
  ]) { $1 }

  lines = [
    "model \(model.id), \(clips.count) clips, hints: \(hints.joined(separator: ", "))",
    "terms \(score.targetHits)/\(score.targetTotal) (caseless \(score.targetHitsCaseless))",
    "controls strict \(score.protectedStrict)/\(score.protectedTotal), unit-normalised \(score.protectedUnitNorm)/\(score.protectedTotal)",
    String(format: "WER %.1f %%", score.werPercent),
    String(format: "finish latency p50 %.0f ms, p90 %.0f ms, max %.0f ms", p50, p90, latencies.last ?? 0),
    String(format: "re-hash %.2f s; load %.2f s (includes a second re-hash); prewarm %.2f s",
      rehash.seconds, load.seconds, prewarm.seconds),
    String(format: "resident MiB: baseline %.0f, after load %.0f, after prewarm %.0f, warm peak %.0f, process peak %.0f",
      baseline.residentMiB, loaded.residentMiB, warmed.residentMiB, warmPeak.residentMiB, end.residentPeakMiB),
    String(format: "resident peak so far, MiB: after re-hash %.0f, after load %.0f, after prewarm %.0f, after corpus, silence and short clips %.0f, at end %.0f",
      rehashed.residentPeakMiB, loaded.residentPeakMiB, warmed.residentPeakMiB, afterCorpus.residentPeakMiB, end.residentPeakMiB),
    String(format: "footprint MiB: baseline %.0f, after load %.0f, warm peak %.0f, process peak %.0f",
      baseline.footprintMiB, loaded.footprintMiB, warmPeak.footprintMiB, end.footprintPeakMiB),
    "per term: " + score.perTerm.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value[0])/\($0.value[1])" }.joined(separator: ", "),
    "gate: " + gate.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value ? "pass" : "FAIL")" }.joined(separator: "; "),
  ] + lines
  let text = lines.joined(separator: "\n") + "\n\nclips:\n" + clips.map {
    String(format: "%@  %4.0f ms  %@", $0.file, $0.analysisMs, $0.text)
  }.joined(separator: "\n") + "\n"
  try text.write(to: out.appending(path: "report.txt"), atomically: true, encoding: .utf8)
  try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appending(path: "report.json"))
  print(text)
  return gate.values.allSatisfy(\.self)
}

do {
  if arguments.contains("--replay") {
    try await replay()
    exit(0)
  }
  exit(try await run() ? 0 : 1)
} catch {
  fail("harness: \(error)")
}
