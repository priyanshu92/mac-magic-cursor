import AVFoundation
import NaturalLanguage

/// Reads assistant replies aloud with the on-device system voices.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
  var onChange: (UUID?) -> Void = { _ in }
  private let synthesizer = AVSpeechSynthesizer()
  private(set) var speakingID: UUID?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func toggle(_ text: String, id: UUID) {
    if speakingID == id {
      stop()
      return
    }
    stop()
    let utterance = AVSpeechUtterance(string: text)
    // Pick a voice for the reply's language; a mismatched voice mispronounces
    // non-English answers such as translations.
    if let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue,
      let voice = AVSpeechSynthesisVoice(language: language)
    {
      utterance.voice = voice
    }
    speakingID = id
    onChange(id)
    synthesizer.speak(utterance)
  }

  func stop() {
    guard speakingID != nil else { return }
    speakingID = nil
    synthesizer.stopSpeaking(at: .immediate)
    onChange(nil)
  }

  // AVSpeechSynthesizer calls its delegate on an arbitrary queue.
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.finished() }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.finished() }
  }

  private func finished() {
    guard !synthesizer.isSpeaking, speakingID != nil else { return }
    speakingID = nil
    onChange(nil)
  }
}
