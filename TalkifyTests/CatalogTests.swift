import CryptoKit
import Foundation
import Testing

@testable import Talkify

struct CatalogTests {
  @Test func theBundledCatalogDecodesAndPassesTheLint() throws {
    let catalog = try Catalog.bundled()
    #expect(!catalog.models.isEmpty)
    #expect(CatalogLint.violations(in: catalog).map(\.description) == [])
  }

  @Test func whisperTurboIsProposedOnSyntheticEvidence() throws {
    let model = try whisper()
    #expect(model.status == .proposed)
    #expect(model.review == nil)
    #expect(model.revoked == nil)
    #expect(model.minHardware.minimumSystemVersion == "26.7")

    let measured = try #require(model.measured)
    #expect(measured.evidence == .synthetic)
    #expect(measured.termHits == CatalogModel.Score(hits: 32, of: 36))
    #expect(measured.controlsUnchanged == CatalogModel.Score(hits: 18, of: 18))
    #expect(measured.wer == 0.012)
  }

  @Test func whisperTurboPinsBothRepositoriesFileByFile() throws {
    let model = try whisper()
    let pins = model.sources.map { "\($0.repository)@\($0.revision)" }
    #expect(pins == [
      "argmaxinc/whisperkit-coreml@0f63a7800b00dd0226abd051b906c246e1907482",
      "openai/whisper-large-v3-turbo@41f01f3fe87f28c78e2fbf8b568835947dd65ed9",
    ])
    #expect(model.files.count == 24)
    #expect(model.totalBytes == 648_662_093)
    let folder = "openai_whisper-large-v3-v20240930_turbo_632MB/"
    #expect(model.installPaths.allSatisfy { $0.hasPrefix(folder) })
    #expect(model.installPaths.contains(folder + "tokenizer.json"))

    let encoder = try #require(model.sources[0].files.first {
      $0.path == folder + "AudioEncoder.mlmodelc/weights/weight.bin"
    })
    #expect(encoder.size == 421_968_768)
    #expect(encoder.sha256 == "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1")
    #expect(model.sources[0].url(for: encoder)?.absoluteString == "https://huggingface.co/"
      + "argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/"
      + folder + "AudioEncoder.mlmodelc/weights/weight.bin")
  }

  @Test(arguments: [
    "main",
    "v1.0",
    "0f63a78",
    "0F63A7800B00DD0226ABD051B906C246E1907482",
    "0f63a7800b00dd0226abd051b906c246e190748",
    "0f63a7800b00dd0226abd051b906c246e1907482a",
    "0f63a7800b00dd0226abd051b906c246e190748g",
  ])
  func aRevisionThatIsNotAFullCommitFails(revision: String) throws {
    var model = try whisper()
    model.sources[0].revision = revision
    #expect(rules(model).contains(.revision))
  }

  @Test func aPlainHTTPTemplateFails() throws {
    var model = try whisper()
    model.sources[0].urlTemplate = "http://huggingface.co/{repository}/resolve/{revision}/{path}"
    #expect(rules(model).contains(.https))
  }

  @Test func anHTTPMirrorFails() throws {
    var model = try whisper()
    model.mirrors = [CatalogModel.Mirror(urlTemplate: "http://example.com/{path}")]
    #expect(rules(model).contains(.https))
  }

  @Test func aHostOffTheAllowlistFails() throws {
    var model = try whisper()
    model.sources[0].host = "hf-mirror.com"
    #expect(rules(model).contains(.host))

    var templated = try whisper()
    templated.sources[1].urlTemplate = "https://huggingface.co.evil.example/{repository}/resolve/{revision}/{path}"
    #expect(rules(templated).contains(.host))
  }

  @Test func aTemplateMissingAPlaceholderFails() throws {
    var model = try whisper()
    model.sources[0].urlTemplate = "https://huggingface.co/{repository}/resolve/main/{path}"
    #expect(rules(model).contains(.urlTemplate))
  }

  @Test(arguments: [
    "../escape.bin",
    "folder/../../escape.bin",
    "/etc/passwd",
    "~/Library/x.bin",
    "folder//weight.bin",
    "./weight.bin",
    "folder\\weight.bin",
    "",
  ])
  func aPathThatCouldLeaveTheInstallFolderFails(path: String) throws {
    var model = try whisper()
    model.sources[1].files[0].path = path
    #expect(rules(model).contains(.path))
  }

  @Test func anInstallFolderThatCouldEscapeFails() throws {
    var model = try whisper()
    model.sources[1].installFolder = "../elsewhere"
    #expect(rules(model).contains(.path))
  }

  @Test func twoFilesLandingOnOnePathFail() throws {
    var model = try whisper()
    model.sources[1].files.append(model.sources[1].files[0])
    model.totalBytes += model.sources[1].files[0].size
    #expect(rules(model) == [.duplicatePath])
  }

  /// The id names the model's folder under the install root, and Delete removes that folder
  /// whole, so an id that is not a plain slug could point either one somewhere else.
  @Test(arguments: ["..", ".", "../Talkify", "a/b", "Whisper-Turbo", "whisper turbo", "-whisper", "whisper.", "a..b"])
  func anIDThatIsNotASlugFails(id: String) throws {
    var model = try whisper()
    model.id = id
    #expect(rules(model) == [.modelID])
  }

  @Test(arguments: ["parakeet-tdt-0.6b-v3-coreml", "whisper-large-v3-turbo-coreml", "a"])
  func aSlugIDPasses(id: String) throws {
    var model = try whisper()
    model.id = id
    #expect(rules(model) == [])
  }

  /// The Mac's volume ignores case, so these two paths are one file on disk: the second
  /// download would overwrite the first and the install could never verify.
  @Test func twoPathsThatDifferOnlyInCaseFail() throws {
    var model = try whisper()
    var shouted = model.sources[1].files[0]
    shouted.path = "Tokenizer.json"
    model.sources[1].files.append(shouted)
    model.totalBytes += shouted.size
    #expect(rules(model) == [.duplicatePath])
  }

  @Test func aFileBeneathAnotherFileFails() throws {
    var model = try whisper()
    var nested = model.sources[1].files[0]
    nested.path = "tokenizer.json/inner.json"
    model.sources[1].files.append(nested)
    model.totalBytes += nested.size
    #expect(rules(model) == [.duplicatePath])
  }

  @Test func aTotalThatDisagreesWithTheFilesFails() throws {
    var model = try whisper()
    model.totalBytes += 1
    #expect(rules(model) == [.totalBytes])

    var grown = try whisper()
    grown.sources[0].files[0].size += 1
    #expect(rules(grown) == [.totalBytes])
  }

  @Test func aMalformedDigestFails() throws {
    var model = try whisper()
    model.sources[0].files[0].sha256 = String(repeating: "a", count: 63)
    #expect(rules(model) == [.sha256])
  }

  @Test func availableRequiresMeasuredNumbers() throws {
    var model = try whisper()
    model.status = .available
    model.review = twoReviewers()
    model.measured = nil
    #expect(rules(model) == [.availableNeedsMeasured])
  }

  @Test func availableRequiresTwoDistinctReviewers() throws {
    var model = try whisper()
    model.status = .available
    #expect(rules(model) == [.availableNeedsTwoReviewers, .availableNeedsNetworkDenyTest])

    model.review = CatalogModel.Review(record: "r.md", networkDenyTest: "pass", reviewer: "alice", secondReviewer: " ")
    #expect(rules(model) == [.availableNeedsTwoReviewers])

    model.review = CatalogModel.Review(record: "r.md", networkDenyTest: "pass", reviewer: "alice", secondReviewer: "Alice")
    #expect(rules(model) == [.availableNeedsTwoReviewers])

    model.review = twoReviewers()
    #expect(rules(model) == [])
  }

  /// ADR-9001 lists an entry only with a network-deny result as well as its reviewers.
  @Test func availableRequiresANetworkDenyResult() throws {
    var model = try whisper()
    model.status = .available
    model.review = twoReviewers()
    model.review?.networkDenyTest = " "
    #expect(rules(model) == [.availableNeedsNetworkDenyTest])
  }

  /// Only Core ML runs in process (ADR-9001); any other format needs an XPC service first.
  @Test(arguments: [CatalogModel.Format.gguf, .safetensors, .json])
  func aFormatThatWouldRunOutsideCoreMLFails(format: CatalogModel.Format) throws {
    var model = try whisper()
    model.format = format
    #expect(rules(model) == [.format])
  }

  @Test(arguments: ["26.6", "26.6.9", "26", "25.9", "26.x", ""])
  func aSystemFloorBelow26Point7Fails(version: String) throws {
    var model = try whisper()
    model.minHardware.minimumSystemVersion = version
    #expect(rules(model) == [.minimumSystemVersion])
  }

  @Test(arguments: ["26.7", "26.7.0", "26.7.3", "26.10", "27"])
  func aSystemFloorAtOrAbove26Point7Passes(version: String) throws {
    var model = try whisper()
    model.minHardware.minimumSystemVersion = version
    #expect(rules(model) == [])
  }

  @Test func revokedStatusNeedsAReason() throws {
    var model = try whisper()
    model.status = .revoked
    #expect(rules(model) == [.revokedNeedsReason])
    model.revoked = CatalogModel.Revocation(date: "2026-11-10", reason: "test", severity: .block)
    #expect(rules(model) == [])
  }

  @Test func aLicenceOffTheAllowlistFails() throws {
    var model = try whisper()
    model.licence.spdx = "CC-BY-NC-4.0"
    #expect(rules(model) == [.licence])
  }

  @Test func aReusedIDFails() throws {
    var catalog = try Catalog.bundled()
    catalog.models.append(catalog.models[0])
    #expect(CatalogLint.violations(in: catalog).map(\.rule) == [.duplicateID])
  }

  @Test(arguments: [
    ("https://huggingface.co/x", true),
    ("https://us.aws.cdn.hf.co/xet-bridge-us/abc", true),
    ("https://cdn-lfs.huggingface.co/repos/x", true),
    ("http://us.aws.cdn.hf.co/xet-bridge-us/abc", false),
    ("https://huggingface.co.evil.example/x", false),
    ("https://evilhuggingface.co/x", false),
    ("https://hf.co.evil.example/cdn.hf.co", false),
    ("https://example.com/x", false),
  ])
  func redirectsStayOnHuggingFaceAndItsCDN(url: String, allowed: Bool) throws {
    #expect(CatalogLint.isRedirectAllowed(to: try #require(URL(string: url))) == allowed)
  }

  private func whisper() throws -> CatalogModel {
    try #require(try Catalog.bundled().models.first { $0.id == "whisper-large-v3-turbo-coreml" })
  }

  private func rules(_ model: CatalogModel) -> [CatalogLint.Rule] {
    CatalogLint.violations(in: model).map(\.rule)
  }

  private func twoReviewers() -> CatalogModel.Review {
    CatalogModel.Review(
      record: "docs/models/reviews/x.md", networkDenyTest: "pass", reviewer: "alice", secondReviewer: "bob")
  }
}

/// Re-hashes a local copy of the Whisper turbo files against the bundled pins. Skipped
/// unless `TALKIFY_WHISPERKIT_FIXTURES` names the folder that holds
/// `openai_whisper-large-v3-v20240930_turbo_632MB/`.
@Suite(
  "Catalog pins against local model files",
  .enabled(if: ProcessInfo.processInfo.environment["TALKIFY_WHISPERKIT_FIXTURES"] != nil)
)
struct CatalogFixtureHashTests {
  @Test func everyPinnedFileMatchesTheLocalCopy() throws {
    let root = URL(filePath: try #require(
      ProcessInfo.processInfo.environment["TALKIFY_WHISPERKIT_FIXTURES"]
    ))
    let model = try #require(try Catalog.bundled().models.first {
      $0.id == "whisper-large-v3-turbo-coreml"
    })
    for source in model.sources {
      for file in source.files {
        let url = root.appending(path: source.installPath(for: file))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
          hasher.update(data: chunk)
          size += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(size == file.size, "\(file.path)")
        #expect(digest == file.sha256, "\(file.path)")
      }
    }
  }
}
