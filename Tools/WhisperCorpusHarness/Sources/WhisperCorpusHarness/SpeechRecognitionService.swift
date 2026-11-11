/// Stands in for the app's Apple Speech actor, which this tool does not build: the
/// Recognizer protocol names only its `Update`.
enum SpeechRecognitionService {
  struct Update: Sendable {
    let finalizedText: String
    let volatileText: String
  }
}
