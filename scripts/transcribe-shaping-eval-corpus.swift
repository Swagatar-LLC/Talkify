// Fills the heard field of every case in the shaping vocabulary corpus:
// synthesizes the reference with `say` in the case's voice, then transcribes
// it with SpeechTranscriber, the recognizer Direct Dictation uses. Synthesized
// speech gives real recognizer mishearings without a microphone or a
// Speech Recognition permission prompt.
//
//   swiftc -parse-as-library -target arm64-apple-macosx26.0 \
//     scripts/transcribe-shaping-eval-corpus.swift -o "$TMPDIR/transcribe-corpus"
//   "$TMPDIR/transcribe-corpus" \
//     TalkifyTests/ShapingVocabularyEval/shaping-vocabulary-corpus.json
//
// Rerun it after an OS update changes the Speech Model, then rerun the eval:
// the heard text is the eval's input, so a new recognizer is a new baseline.

import AVFoundation
import Foundation
import Speech

@main
struct TranscribeCorpus {
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else {
      print("usage: transcribe-corpus <corpus.json>")
      exit(64)
    }
    let corpusURL = URL(filePath: CommandLine.arguments[1])
    var corpus = try JSONSerialization.jsonObject(
      with: Data(contentsOf: corpusURL)
    ) as! [String: Any]
    var cases = corpus["cases"] as! [[String: Any]]

    let locale = Locale(identifier: "en-US")
    let probe = SpeechTranscriber(locale: locale, preset: .transcription)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
      try await request.downloadAndInstall()
    }

    let workspace = URL.temporaryDirectory.appending(path: "shaping-eval-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    for index in cases.indices {
      let id = cases[index]["id"] as! String
      let voice = cases[index]["voice"] as! String
      let reference = cases[index]["reference"] as! String
      let audio = workspace.appending(path: "\(id).aiff")

      let say = Process()
      say.executableURL = URL(filePath: "/usr/bin/say")
      say.arguments = ["-v", voice, "-o", audio.path(percentEncoded: false), reference]
      try say.run()
      say.waitUntilExit()
      guard say.terminationStatus == 0 else {
        print("say failed for \(id) with voice \(voice)")
        exit(1)
      }

      let heard = try await transcribe(audio, locale: locale)
      cases[index]["heard"] = heard
      print("\(id) [\(voice)] \(heard)")
    }

    corpus["cases"] = cases
    let data = try JSONSerialization.data(
      withJSONObject: corpus,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try (data + Data("\n".utf8)).write(to: corpusURL)
  }

  /// A fresh transcriber and analyzer per file, so no context carries from
  /// one case into the next.
  static func transcribe(_ url: URL, locale: Locale) async throws -> String {
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: url)
    async let text: String = {
      var text = ""
      for try await result in transcriber.results where result.isFinal {
        text += String(result.text.characters)
      }
      return text
    }()
    if let last = try await analyzer.analyzeSequence(from: file) {
      try await analyzer.finalizeAndFinish(through: last)
    } else {
      await analyzer.cancelAndFinishNow()
    }
    return try await text.trimmingCharacters(in: .whitespaces)
  }
}
