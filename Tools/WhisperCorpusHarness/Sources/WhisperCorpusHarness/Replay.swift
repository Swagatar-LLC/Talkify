import AVFAudio
import Foundation
import os

// Paced PCM only: no audio device, application lifecycle, or network probe.
func replay() async throws {
  let clock = ContinuousClock()
  let catalog = try Catalog(data: Data(contentsOf: URL(filePath: #filePath)
    .deletingLastPathComponent().appending(path: "Talkify/Catalog/catalog.json")))
  let model = catalog.models.first { $0.runtime.id == WhisperRecognizer.runtimeID }!
  let installer = CatalogInstaller(root: fixtures, compiledModelCache: nil, catalogVersion: catalog.catalogVersion)
  let before = Memory.sample()
  let loadStart = clock.now
  let recognizer = try await WhisperRecognizer.load(model: model) { try installer.verifiedFolder(for: model) }
  let loaded = Memory.sample()
  let loadSeconds = (clock.now - loadStart).seconds
  try await recognizer.prewarm()
  let warmed = Memory.sample()
  let corpus = try JSONDecoder().decode([CorpusScore.Sentence].self,
    from: Data(contentsOf: corpusFolder.appending(path: "corpus.json")))
  var hints: [String] = []
  for sentence in corpus { for term in sentence.targets where !hints.contains(term) { hints.append(term) } }
  await recognizer.setHints(hints)
  let files = try wavs(in: corpusFolder.appending(path: "wav"))
  let selected = files.filter { $0.lastPathComponent.contains("_alex") }
  guard !selected.isEmpty else { throw HarnessError(description: "no Alex fixtures") }
  var long: [Float] = []
  for file in selected { long += try readSamples(file) + [Float](repeating: 0, count: 4_800) }
  let cases: [(String, [Float])] = [
    (selected[0].lastPathComponent, try readSamples(selected[0])),
    ("long-alex-concatenation", long),
    ("silence-5s", [Float](repeating: 0, count: 80_000)),
  ]
  try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  let output = out.appending(path: "replay.jsonl")
  FileManager.default.createFile(atPath: output.path, contents: nil)
  let handle = try FileHandle(forWritingTo: output)
  defer { try? handle.close() }
  for repetition in 1...2 {
    for (name, samples) in cases {
      let start = clock.now
      let updates = OSAllocatedUnfairLock(initialState: [(Double, String)]())
      try await recognizer.start(locale: Locale(identifier: "en_US"), updateHandler: { update in
        guard !update.volatileText.isEmpty else { return }
        updates.withLock { $0.append(((clock.now - start).seconds, update.volatileText)) }
      }) { format in
        guard format == WhisperRecognizer.format else { throw HarnessError(description: "unexpected format") }
      }
      var peak = warmed
      for offset in stride(from: 0, to: samples.count, by: 1_600) {
        let count = min(1_600, samples.count - offset)
        let buffer = AVAudioPCMBuffer(pcmFormat: WhisperRecognizer.format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + offset, count: count) }
        guard recognizer.feed(buffer) else { throw HarnessError(description: "dropped PCM") }
        try await clock.sleep(until: start.advanced(by: .seconds(Double(offset + count) / 16_000)))
        peak = peak.max(Memory.sample())
      }
      let finishStart = clock.now
      let text = try await recognizer.finish()
      let finishMs = (clock.now - finishStart).milliseconds
      peak = peak.max(Memory.sample())
      let drafts = updates.withLock { $0 }.map { ["seconds": $0.0, "text": $0.1] as [String: Any] }
      let row: [String: Any] = [
        "case": name, "repetition": repetition, "audioSeconds": Double(samples.count) / 16_000,
        "drafts": drafts, "finalText": text, "finishMs": finishMs,
        "feedSeconds": (finishStart - start).seconds, "loadSeconds": loadSeconds,
        "baselineRSSMiB": before.residentMiB, "loadedRSSMiB": loaded.residentMiB,
        "warmedRSSMiB": warmed.residentMiB, "sampledPeakRSSMiB": peak.residentMiB,
        "processPeakRSSMiB": peak.residentPeakMiB, "loadedFootprintMiB": loaded.footprintMiB,
        "peakFootprintMiB": peak.footprintPeakMiB,
      ]
      try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
      try handle.write(contentsOf: Data("\n".utf8))
      try handle.synchronize()
      print("\(name) #\(repetition): drafts \(drafts.count), finish \(finishMs) ms")
    }
  }
}
