import AppKit
import MagicCursorCore
import SwiftUI

/// What happens after the user selects a region.
enum SelectionMode: String, CaseIterable, Sendable {
  /// Explain the selection right away, then offer follow-up suggestions.
  case answerImmediately
  /// Like Googlebook Magic Pointer: show suggestions and wait for a question.
  case suggestFirst

  var title: String {
    switch self {
    case .answerImmediately: "Answer right away"
    case .suggestFirst: "Suggest first"
    }
  }
}

/// One captured region with its locally recognized text.
struct CapturedSelection: Identifiable {
  let id = UUID()
  let image: CGImage
  let preview: NSImage
  var text = ""
  var warning: String?
}

@MainActor
final class AppModel: ObservableObject {
  typealias CaptureOperation =
    @Sendable (CGDirectDisplayID, CGRect, CGFloat) async throws -> CGImage
  typealias RecognitionOperation = @Sendable (CGImage) async throws -> String
  typealias ResponseOperation =
    @MainActor ([CGImage], String, String, String, @MainActor (String) -> Void) async throws
    -> Void
  typealias InsightsOperation =
    @MainActor ([CGImage], String) async throws -> SelectionInsights

  enum Phase: Equatable {
    case idle, selecting, capturing, answering, ready
    var isBusy: Bool { self == .capturing || self == .answering }
  }

  static let maximumSelections = 4
  static let initialPrompt = "Explain what I selected. If it is text, summarize the main point."
  static let defaultCardWidth: CGFloat = 384
  static let cardWidthRange: ClosedRange<CGFloat> = 340...760
  static let minimumCardHeight: CGFloat = 240

  @Published var phase: Phase = .idle
  @Published private(set) var selections: [CapturedSelection] = []
  @Published private(set) var messages: [ChatMessage] = []
  @Published private(set) var conversationID = UUID()
  @Published private(set) var conversationTitle: String?
  @Published private(set) var suggestions: [String] = []
  @Published private(set) var suggestionsLoading = false
  @Published private(set) var usedSuggestions: Set<String> = []
  @Published private(set) var speakingMessageID: UUID?
  @Published var followsLatestReply = true
  /// Measured conversation height; the panel card hugs it until it must scroll.
  @Published var cardContentHeight: CGFloat = 0
  /// Measured fixed card chrome, used to cap the scrolling area's height.
  @Published var cardHeaderHeight: CGFloat = 0
  @Published var cardComposerHeight: CGFloat = 0
  /// Height available for the card and pills on the current display.
  @Published var panelMaxHeight: CGFloat = 640
  /// Measured height of the card, pills, and shadow margins; drives the window size.
  @Published var panelContentHeight: CGFloat = 0
  /// User-chosen card width, persisted across launches.
  @Published var cardWidth: CGFloat {
    didSet { defaults.setSetting(Double(cardWidth), forKey: "cardWidth") }
  }
  /// User-chosen answer-card height; nil means the card hugs its content.
  @Published var userCardHeight: CGFloat? {
    didSet {
      if let userCardHeight {
        defaults.setSetting(Double(userCardHeight), forKey: "cardHeight")
      } else {
        defaults.setSetting(nil, forKey: "cardHeight")
      }
    }
  }
  /// Last measured card height, read when a resize drag starts. Not published
  /// because nothing renders from it.
  var measuredCardHeight: CGFloat = 0
  var isCustomSize: Bool {
    userCardHeight != nil || cardWidth != Self.defaultCardWidth
  }
  var isUserScrolling = false
  @Published var errorMessage: String?
  @Published var modelMessage: String?
  @Published var screenPermission = CGPreflightScreenCaptureAccess()
  @Published var question = ""
  @Published var showRecognizedText = false
  @Published var showSettings = false
  @Published var shakeEnabled: Bool {
    didSet { defaults.setSetting(shakeEnabled, forKey: "shakeEnabled") }
  }
  @Published var sensitivity: ShakeDetector.Sensitivity {
    didSet { defaults.setSetting(sensitivity.rawValue, forKey: "sensitivity") }
  }
  @Published var selectionMode: SelectionMode {
    didSet { defaults.setSetting(selectionMode.rawValue, forKey: "selectionMode") }
  }

  var selectRegion: () -> Void = {}
  var addRegion: () -> Void = {}
  var closePanel: () -> Void = {}
  var openSettings: () -> Void = {}

  var preview: NSImage? { selections.first?.preview }
  var answer: String {
    messages.last(where: { $0.role == .assistant })?.content ?? ""
  }
  var recognizedText: String {
    let texts = selections.map(\.text).filter { !$0.isEmpty }
    guard selections.count > 1 else { return texts.first ?? "" }
    return selections.enumerated().compactMap { index, selection in
      selection.text.isEmpty ? nil : "Selection \(index + 1):\n\(selection.text)"
    }.joined(separator: "\n\n")
  }
  var recognitionWarning: String? {
    let warnings = selections.compactMap(\.warning)
    return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
  }
  var showsNoTextMessage: Bool {
    preview != nil && !phase.isBusy && recognizedText.isEmpty && recognitionWarning == nil
  }
  var visibleSuggestions: [String] { suggestions.filter { !usedSuggestions.contains($0) } }
  var canAddSelection: Bool {
    !selections.isEmpty && selections.count < Self.maximumSelections && !phase.isBusy
  }
  /// The card shows the compact prompt layout until the first question.
  var showsPromptCard: Bool { !selections.isEmpty && messages.isEmpty }
  var headerTitle: String {
    if let conversationTitle { return conversationTitle }
    if let question = messages.first(where: { $0.role == .user })?.content {
      return String(question.prefix(32))
    }
    return selections.count > 1 ? "Your selections" : "Your selection"
  }

  private var work: Task<Void, Never>?
  private var insightsWork: Task<Void, Never>?
  private var generation = UUID()
  private var insightsGeneration = UUID()
  private var insightsRequested = false
  private var activeResponseID: UUID?
  private let defaults: any SettingsStore
  private let capture: CaptureOperation
  private let recognize: RecognitionOperation
  private let availability: @MainActor () -> String?
  private let respond: ResponseOperation
  private let insights: InsightsOperation
  private let speaker = Speaker()

  init(
    capture: @escaping CaptureOperation = CaptureService.capture,
    recognize: @escaping RecognitionOperation = CaptureService.recognizeText,
    availability: @escaping @MainActor () -> String? = { AssistantEngine.availabilityMessage },
    respond: @escaping ResponseOperation = AssistantEngine.answer,
    insights: @escaping InsightsOperation = AssistantEngine.insights,
    defaults: any SettingsStore = UserDefaults.standard
  ) {
    self.capture = capture
    self.recognize = recognize
    self.availability = availability
    self.respond = respond
    self.insights = insights
    self.defaults = defaults
    modelMessage = availability()
    shakeEnabled = defaults.setting(forKey: "shakeEnabled") as? Bool ?? true
    sensitivity =
      ShakeDetector.Sensitivity(
        rawValue: (defaults.setting(forKey: "sensitivity") as? String) ?? "") ?? .standard
    selectionMode =
      SelectionMode(rawValue: (defaults.setting(forKey: "selectionMode") as? String) ?? "")
      ?? .answerImmediately
    let savedWidth = defaults.setting(forKey: "cardWidth") as? Double
    cardWidth = Self.clampWidth(savedWidth.map { CGFloat($0) } ?? Self.defaultCardWidth)
    let savedHeight = defaults.setting(forKey: "cardHeight") as? Double
    userCardHeight = savedHeight.map { max(Self.minimumCardHeight, CGFloat($0)) }
    speaker.onChange = { [weak self] id in self?.speakingMessageID = id }
  }

  static func clampWidth(_ width: CGFloat) -> CGFloat {
    guard width.isFinite else { return defaultCardWidth }
    return min(max(width, cardWidthRange.lowerBound), cardWidthRange.upperBound)
  }

  func resetCardSize() {
    cardWidth = Self.defaultCardWidth
    userCardHeight = nil
  }

  func refreshAvailability() {
    let previouslyGranted = screenPermission
    screenPermission = CGPreflightScreenCaptureAccess()
    if screenPermission && !previouslyGranted { errorMessage = nil }
    modelMessage = availability()
  }

  func requestPermission() {
    if CGRequestScreenCaptureAccess() {
      errorMessage = nil
      refreshAvailability()
    } else {
      errorMessage = CaptureService.CaptureError.permissionDenied.localizedDescription
      refreshAvailability()
    }
  }

  func beginSelection() {
    stop()
    errorMessage = nil
    phase = .selecting
  }

  func cancelSelection() {
    phase = preview == nil ? .idle : .ready
  }

  /// Starts a new chat about one freshly captured region.
  func process(displayID: CGDirectDisplayID, rectangle: CGRect, scale: CGFloat) {
    stop()
    cancelInsights()
    let token = generation
    selections = []
    messages = []
    conversationID = UUID()
    conversationTitle = nil
    suggestions = []
    usedSuggestions = []
    insightsRequested = false
    followsLatestReply = true
    isUserScrolling = false
    errorMessage = nil
    question = ""
    phase = .capturing
    work = Task {
      do {
        guard try await captureSelection(displayID, rectangle, scale, token: token) else { return }
        refreshAvailability()
        guard modelMessage == nil else {
          phase = .ready
          work = nil
          return
        }
        if selectionMode == .suggestFirst {
          phase = .ready
          work = nil
          startInsights()
          return
        }
        let response = beginResponse(userQuestion: nil)
        try await generate(question: Self.initialPrompt, token: token, response: response)
      } catch {
        finish(error: error, token: token)
      }
    }
  }

  /// Adds another region to the current chat, like Magic Pointer's multi-select.
  func addSelection(displayID: CGDirectDisplayID, rectangle: CGRect, scale: CGFloat) {
    guard !selections.isEmpty, selections.count < Self.maximumSelections else { return }
    stop()
    let token = generation
    errorMessage = nil
    phase = .capturing
    work = Task {
      do {
        guard try await captureSelection(displayID, rectangle, scale, token: token) else { return }
        refreshAvailability()
        phase = .ready
        work = nil
        if modelMessage == nil { startInsights() }
      } catch {
        finish(error: error, token: token)
      }
    }
  }

  func removeSelection(_ id: CapturedSelection.ID) {
    guard selections.count > 1 else {
      clear()
      return
    }
    selections.removeAll { $0.id == id }
    if modelMessage == nil && !phase.isBusy { startInsights() }
  }

  /// Captures and recognizes one region and appends it. Returns false when a
  /// newer operation superseded this one.
  private func captureSelection(
    _ displayID: CGDirectDisplayID, _ rectangle: CGRect, _ scale: CGFloat, token: UUID
  ) async throws -> Bool {
    let image = try await capture(displayID, rectangle, scale)
    try Task.checkCancellation()
    guard generation == token else { return false }
    var selection = CapturedSelection(
      image: image,
      preview: NSImage(
        cgImage: image, size: NSSize(width: rectangle.width, height: rectangle.height)))
    do {
      selection.text = try await recognize(image)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // OCR can reject tiny or image-only crops. Keep the successful
      // capture for multimodal analysis and expose the failure.
      selection.warning =
        "Text recognition failed for this selection: \(error.localizedDescription)"
    }
    try Task.checkCancellation()
    guard generation == token else { return false }
    selections.append(selection)
    return true
  }

  func ask(_ prompt: String? = nil) {
    let query = (prompt ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, !selections.isEmpty, !phase.isBusy else { return }
    refreshAvailability()
    guard modelMessage == nil else {
      errorMessage = modelMessage
      return
    }
    if let prompt, suggestions.contains(prompt) { usedSuggestions.insert(prompt) }
    stop()
    let token = generation
    question = ""
    errorMessage = nil
    let response = beginResponse(userQuestion: query)
    work = Task {
      do { try await generate(question: query, token: token, response: response) } catch {
        finish(error: error, token: token)
      }
    }
  }

  private func beginResponse(userQuestion: String?) -> (id: UUID, context: String) {
    let context = conversationContext()
    if let userQuestion {
      messages.append(ChatMessage(role: .user, content: userQuestion))
    }
    let response = ChatMessage(role: .assistant, content: "", status: .streaming)
    messages.append(response)
    activeResponseID = response.id
    followsLatestReply = true
    isUserScrolling = false
    phase = .answering
    return (response.id, context)
  }

  private func conversationContext() -> String {
    var remaining = 2000
    var context: [String] = []
    for message in messages.reversed() where message.status == .complete && !message.content.isEmpty
    {
      let role = message.role == .user ? "User: " : "Assistant: "
      guard remaining > role.count else { break }
      let line = role + String(message.content.prefix(remaining - role.count))
      context.append(line)
      remaining -= line.count + 2
    }
    return context.reversed().joined(separator: "\n\n")
  }

  private func generate(
    question: String, token: UUID, response: (id: UUID, context: String)
  ) async throws {
    guard !selections.isEmpty else { return }
    try await respond(selections.map(\.image), recognizedText, question, response.context) {
      [weak self] text in
      guard let self, self.generation == token,
        let index = self.messages.firstIndex(where: { $0.id == response.id })
      else { return }
      self.messages[index].content = text
    }
    try Task.checkCancellation()
    guard generation == token else { return }
    if let index = messages.firstIndex(where: { $0.id == response.id }) {
      messages[index].status = .complete
    }
    activeResponseID = nil
    phase = .ready
    work = nil
    if !insightsRequested { startInsights() }
  }

  private func finish(error: Error, token: UUID) {
    guard generation == token else { return }
    if let activeResponseID, let index = messages.firstIndex(where: { $0.id == activeResponseID }) {
      messages[index].status = error is CancellationError ? .cancelled : .failed
      if !(error is CancellationError) {
        messages[index].errorMessage = error.localizedDescription
      }
    }
    activeResponseID = nil
    phase = preview == nil ? .idle : .ready
    work = nil
    if !(error is CancellationError) {
      errorMessage = error.localizedDescription
    }
  }

  /// Requests a title and suggestion chips for the current selections.
  /// Failures are silent: suggestions are optional and the chat still works.
  private func startInsights() {
    cancelInsights()
    guard !selections.isEmpty else { return }
    let token = insightsGeneration
    insightsRequested = true
    suggestionsLoading = true
    let images = selections.map(\.image)
    let text = recognizedText
    insightsWork = Task {
      let result = try? await insights(images, text)
      guard insightsGeneration == token, !Task.isCancelled else { return }
      suggestionsLoading = false
      insightsWork = nil
      guard let result else { return }
      if let title = result.title { conversationTitle = title }
      suggestions = result.suggestions
    }
  }

  private func cancelInsights() {
    insightsGeneration = UUID()
    insightsWork?.cancel()
    insightsWork = nil
    suggestionsLoading = false
  }

  func stop() {
    // A cancelled framework operation can still return later. Invalidate its
    // generation before cancelling so it cannot overwrite a newer selection.
    generation = UUID()
    if let activeResponseID, let index = messages.firstIndex(where: { $0.id == activeResponseID }) {
      messages[index].status = .cancelled
    }
    activeResponseID = nil
    work?.cancel()
    work = nil
    phase = preview == nil ? .idle : .ready
  }

  func clear() {
    stop()
    cancelInsights()
    speaker.stop()
    selections = []
    messages = []
    conversationID = UUID()
    conversationTitle = nil
    suggestions = []
    usedSuggestions = []
    insightsRequested = false
    followsLatestReply = true
    isUserScrolling = false
    question = ""
    errorMessage = nil
    phase = .idle
  }

  func toggleSpeech(_ message: ChatMessage) {
    speaker.toggle(message.plainText, id: message.id)
  }

  func stopSpeaking() {
    speaker.stop()
  }

  func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
