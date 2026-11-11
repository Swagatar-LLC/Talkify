import Darwin
import Foundation

/// The spike's scoring rules (`score.py`, extended by `score2.py`): terms and controls are
/// case-sensitive and word-bounded; the unit-normalised count also accepts "3mm" and
/// "3 millimeters" for "3 mm"; WER is lower-cased with punctuation stripped.
struct CorpusScore {
  struct Sentence: Codable {
    var id: String
    var text: String
    var targets: [String]
    var protect: [String]
  }

  struct Result {
    var targetHits = 0, targetTotal = 0, targetHitsCaseless = 0
    var protectedStrict = 0, protectedUnitNorm = 0, protectedTotal = 0
    var werPercent = 0.0
    var perTerm: [String: [Int]] = [:]
  }

  let sentences: [String: Sentence]

  init(corpus: [Sentence]) {
    sentences = Dictionary(uniqueKeysWithValues: corpus.map { ($0.id, $0) })
  }

  func score(_ outputs: [(file: String, text: String)]) -> Result {
    var result = Result()
    var errors = 0, words = 0
    for output in outputs {
      guard let sentence = sentences[String(output.file.prefix { $0 != "_" })] else { continue }
      for term in sentence.targets {
        let hit = Self.has(output.text, term)
        result.targetTotal += 1
        result.targetHits += hit ? 1 : 0
        result.targetHitsCaseless += Self.has(output.text.lowercased(), term.lowercased(), letters: "a-z") ? 1 : 0
        result.perTerm[term, default: [0, 0]][0] += hit ? 1 : 0
        result.perTerm[term, default: [0, 0]][1] += 1
      }
      for term in sentence.protect {
        result.protectedTotal += 1
        result.protectedStrict += Self.has(output.text, term) ? 1 : 0
        result.protectedUnitNorm += Self.has(Self.unitNormalised(output.text), term) ? 1 : 0
      }
      let reference = Self.words(sentence.text)
      errors += Self.editDistance(reference, Self.words(output.text))
      words += reference.count
    }
    result.werPercent = words == 0 ? 0 : (1000 * Double(errors) / Double(words)).rounded() / 10
    return result
  }

  static func has(_ text: String, _ term: String, letters: String = "A-Za-z") -> Bool {
    let pattern = "(?<![\(letters)])" + NSRegularExpression.escapedPattern(for: term) + "(?![\(letters)])"
    return text.range(of: pattern, options: .regularExpression) != nil
  }

  static func unitNormalised(_ text: String) -> String {
    text.replacingOccurrences(of: #"(\d)\s*(mm|millimeters?)\b"#, with: "$1 mm", options: .regularExpression)
  }

  static func words(_ text: String) -> [String] {
    unitNormalised(text).lowercased()
      .replacingOccurrences(of: "[^a-z0-9' ]+", with: " ", options: .regularExpression)
      .split(separator: " ").map(String.init)
  }

  static func editDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
    guard !reference.isEmpty else { return hypothesis.count }
    guard !hypothesis.isEmpty else { return reference.count }
    var row = Array(0...hypothesis.count)
    for i in 1...reference.count {
      var previous = row[0]
      row[0] = i
      for j in 1...hypothesis.count {
        let current = min(row[j] + 1, row[j - 1] + 1, previous + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1))
        previous = row[j]
        row[j] = current
      }
    }
    return row[hypothesis.count]
  }

  static func median(_ sorted: [Double]) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }
}

/// Resident size and physical footprint of this process, now and at its peak.
struct Memory {
  var residentMiB: Double
  var residentPeakMiB: Double
  var footprintMiB: Double
  var footprintPeakMiB: Double

  func max(_ other: Memory) -> Memory {
    Memory(
      residentMiB: Swift.max(residentMiB, other.residentMiB),
      residentPeakMiB: Swift.max(residentPeakMiB, other.residentPeakMiB),
      footprintMiB: Swift.max(footprintMiB, other.footprintMiB),
      footprintPeakMiB: Swift.max(footprintPeakMiB, other.footprintPeakMiB))
  }

  static func sample() -> Memory {
    var basic = mach_task_basic_info()
    var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &basic) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
      }
    }
    var vm = task_vm_info_data_t()
    var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &vm) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
      }
    }
    let mebibyte = 1_048_576.0
    return Memory(
      residentMiB: Double(basic.resident_size) / mebibyte,
      residentPeakMiB: Double(basic.resident_size_max) / mebibyte,
      footprintMiB: Double(vm.phys_footprint) / mebibyte,
      footprintPeakMiB: Double(vm.ledger_phys_footprint_peak) / mebibyte)
  }
}

/// The positive control for the network-deny run, from inside the measured process.
enum NetworkProbe {
  /// "connected", or "blocked: <errno>" when the socket cannot be opened or connected.
  static func attempt() -> String {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return "blocked: socket() \(String(cString: strerror(errno)))" }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(443).bigEndian
    inet_pton(AF_INET, "1.1.1.1", &address.sin_addr)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return result == 0 ? "connected" : "blocked: connect() \(String(cString: strerror(errno)))"
  }
}

extension Duration {
  var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
  var milliseconds: Double { seconds * 1000 }
}

extension JSONEncoder {
  static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return encoder
  }
}
