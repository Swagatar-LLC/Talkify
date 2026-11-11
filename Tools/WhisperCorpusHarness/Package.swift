// swift-tools-version: 6.0
import PackageDescription

// Runs the hint-spike corpus through the app's own Whisper Recognizer, outside Xcode's test
// runner so the whole process can sit under `sandbox-exec` with the network denied: a hosted
// test cannot, because the runner talks to xcodebuild over a socket.
//
// `Sources/WhisperCorpusHarness/Talkify/` links to the app's files rather than copying them,
// so this measures the code that ships. WhisperKit is pinned to the same exact version as
// the app.
let package = Package(
  name: "WhisperCorpusHarness",
  platforms: [.macOS("26.0")],
  dependencies: [
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
  ],
  targets: [
    .executableTarget(
      name: "WhisperCorpusHarness",
      dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
      // The store belongs to Settings and reads AppSettings, which this tool does not build.
      exclude: [
        "Talkify/Catalog/catalog.json",
        "Talkify/Catalog/RecognizerStore.swift",
        "Talkify/Catalog/RecognizerStore+Live.swift",
      ]
    ),
  ]
)
