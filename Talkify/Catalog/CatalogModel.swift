import Foundation

/// One open-weight speech recognizer the user may choose to download, pinned to exact bytes.
///
/// Every file the runtime opens is listed with its size and SHA-256, under a full commit of
/// the repository it comes from. A model may draw on more than one repository (a converted
/// model plus the upstream tokenizer), so the files are grouped by source.
struct CatalogModel: Codable, Equatable, Sendable, Identifiable {
  /// Stable forever; never reused, even after revocation.
  var id: String
  var displayName: String
  var status: Status
  var publisher: Publisher
  var sources: [Source]
  /// Transport only, never trusted: the same hashes apply to whatever they serve.
  var mirrors: [Mirror]
  /// The sum of every file's `size`, shown before download.
  var totalBytes: Int64
  var format: Format
  var runtime: Runtime
  var licence: Licence
  /// BCP-47 tags this model is listed for, intersected with the Dictation Languages.
  var languages: [String]
  var minHardware: MinHardware
  var measured: Measured?
  var review: Review?
  var revoked: Revocation?

  var files: [File] { sources.flatMap(\.files) }

  /// Every file's path under the install root, in catalog order.
  var installPaths: [String] {
    sources.flatMap { source in source.files.map { source.installPath(for: $0) } }
  }

  enum Status: String, Codable, Sendable {
    /// Listed in the repo, never offered for download.
    case proposed
    /// Offered for download; requires measurements and two reviewers.
    case available
    /// Never loaded again at `block` severity; the session falls back to Apple Speech.
    case revoked
  }

  struct Publisher: Codable, Equatable, Sendable {
    var weights: String
    /// Set when a third party converted the upstream weights.
    var conversion: String?
  }

  struct Source: Codable, Equatable, Sendable {
    var host: String
    var repository: String
    /// A full 40-hex commit; branch and tag names fail the lint.
    var revision: String
    /// `https://huggingface.co/{repository}/resolve/{revision}/{path}`.
    var urlTemplate: String
    /// The original publisher's repository, for review traceability.
    var upstreamRepository: String?
    /// A folder under the install root that this source's files land in, so files from two
    /// repositories can share one model folder. `nil` installs at the root.
    var installFolder: String?
    var files: [File]

    func installPath(for file: File) -> String {
      guard let installFolder, !installFolder.isEmpty else { return file.path }
      return installFolder + "/" + file.path
    }

    func url(for file: File) -> URL? {
      URL(string: urlTemplate
        .replacingOccurrences(of: "{repository}", with: repository)
        .replacingOccurrences(of: "{revision}", with: revision)
        .replacingOccurrences(of: "{path}", with: file.path))
    }
  }

  struct File: Codable, Equatable, Sendable {
    /// Relative to the source repository's root at `revision`.
    var path: String
    var size: Int64
    var sha256: String
  }

  struct Mirror: Codable, Equatable, Sendable {
    var urlTemplate: String
  }

  enum Format: String, Codable, Sendable {
    case coreMLCompiled = "coreml-mlmodelc"
    case coreMLPackage = "coreml-mlpackage"
    case gguf
    case safetensors
    case json
  }

  struct Runtime: Codable, Equatable, Sendable {
    var id: String
    var minVersion: String
  }

  struct Licence: Codable, Equatable, Sendable {
    var spdx: String
    var url: String
    /// Shown in Acknowledgements when the licence asks for it.
    var attribution: String?
  }

  struct MinHardware: Codable, Equatable, Sendable {
    var arch: String
    var minimumSystemVersion: String
    var memoryGB: Int?
    var neuralEngine: Bool
  }

  /// The numbers that justify listing the model, against Apple on the same corpus.
  struct Measured: Codable, Equatable, Sendable {
    var evidence: Evidence
    /// Corpus name plus the SHA-256 of its `corpus.json`.
    var corpus: String
    var termHits: Score
    var controlsUnchanged: Score
    /// Word error rate as a fraction, lower-cased with punctuation stripped.
    var wer: Double?
    var appleBaseline: Baseline
    var latencyMillisecondsMedian: Int?
    var latencyMillisecondsP90: Int?
    var coldLoadSeconds: Double?
    var warmLoadSeconds: Double?
    var peakRSSMiBCold: Int?
    var peakRSSMiBWarm: Int?
    var machine: String
    var notes: String?

    enum Evidence: String, Codable, Sendable {
      /// Text-to-speech audio; real-voice numbers replace these after the soak.
      case synthetic
      case realVoice = "real-voice"
    }

    struct Baseline: Codable, Equatable, Sendable {
      var arm: String
      var termHits: Score
      var controlsUnchanged: Score
      var wer: Double?
    }
  }

  struct Score: Codable, Equatable, Sendable {
    var hits: Int
    var of: Int
  }

  struct Review: Codable, Equatable, Sendable {
    var record: String
    var networkDenyTest: String?
    var reviewer: String?
    var secondReviewer: String?
    var date: String?
  }

  struct Revocation: Codable, Equatable, Sendable {
    var date: String
    var reason: String
    var severity: Severity

    enum Severity: String, Codable, Sendable {
      /// Still loads; Settings recommends switching.
      case advisory
      /// Never loaded again.
      case block
    }
  }
}
