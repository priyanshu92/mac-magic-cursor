import AppKit
import Foundation
import ImageIO
import MagicCursorCore

@main
enum NativeChecks {
  /// Thread-safe counter for @Sendable recognition stubs.
  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
      lock.lock()
      defer { lock.unlock() }
      value += 1
      return value
    }
  }

  /// Each model gets its own in-memory settings, so a setting changed by one
  /// check, such as the selection mode, cannot leak into later checks, and no
  /// check ever writes to the user's Preferences folder.
  @MainActor static func isolatedDefaults() -> MemorySettingsStore { MemorySettingsStore() }

  /// Keeps checks from invoking the real on-device model for suggestions.
  @MainActor static var noInsights: AppModel.InsightsOperation {
    { _, _ in SelectionInsights() }
  }

  enum CheckError: LocalizedError {
    case recognition
    case capture
    case response
    var errorDescription: String? {
      switch self {
      case .recognition: "Expected OCR failure"
      case .capture: "Expected capture failure"
      case .response: "Expected response failure"
      }
    }
  }

  @MainActor
  static func main() async throws {
    if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--ocr-image" {
      let url = URL(fileURLWithPath: CommandLine.arguments[2])
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        print("FAIL: Could not decode the provided OCR fixture")
        exit(1)
      }
      let fixture: CGImage
      if CommandLine.arguments.count == 8, CommandLine.arguments[3] == "--crop",
        let x = Double(CommandLine.arguments[4]), let y = Double(CommandLine.arguments[5]),
        let width = Double(CommandLine.arguments[6]), let height = Double(CommandLine.arguments[7]),
        let crop = image.cropping(to: CGRect(x: x, y: y, width: width, height: height))
      {
        fixture = crop
      } else if CommandLine.arguments.count == 3 {
        fixture = image
      } else {
        print("Usage: --ocr-image image.png [--crop x y width height]")
        exit(2)
      }
      try await checkImage(fixture, label: "provided image")
      return
    }
    var passed = 0
    var failed = 0
    func check(_ name: String, _ condition: @autoclosure () -> Bool) {
      if condition() {
        passed += 1
      } else {
        failed += 1
        print("FAIL: \(name)")
      }
    }
    func waitForWork(_ model: AppModel) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while model.phase.isBusy && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      check("Work completes within deadline", !model.phase.isBusy)
    }
    func waitUntil(_ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !condition() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      check("Condition met within deadline", condition())
    }

    let canvas = NSImage(size: NSSize(width: 700, height: 180))
    canvas.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 700, height: 180)).fill()
    ("Magic Cursor recognizes text locally." as NSString).draw(
      at: NSPoint(x: 30, y: 75),
      withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]
    )
    canvas.unlockFocus()
    guard let image = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      print("FAIL: Could not create OCR fixture")
      exit(1)
    }
    let realText = try await CaptureService.recognizeText(in: image)
    check("Real Vision OCR reads generated image", realText.contains("recognizes text locally"))

    if CommandLine.arguments.contains("--ocr-formats") {
      let formats: [(String, Int, CGBitmapInfo, CFString)] = [
        ("sRGB RGBA8", 8, [], CGColorSpace.sRGB),
        ("Display P3 BGRA8", 8, [.byteOrder32Little], CGColorSpace.displayP3),
        (
          "extended-linear sRGB RGBA32", 32, [.floatComponents, .byteOrder32Little],
          CGColorSpace.extendedLinearSRGB
        ),
      ]
      for (label, bits, info, spaceName) in formats {
        let alpha =
          label.contains("BGRA") ? CGImageAlphaInfo.premultipliedFirst : .premultipliedLast
        guard let space = CGColorSpace(name: spaceName),
          let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: bits, bytesPerRow: 0, space: space,
            bitmapInfo: info.rawValue | alpha.rawValue
          )
        else {
          print("FAIL: Could not create \(label) fixture")
          exit(1)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let fixture = context.makeImage() else {
          print("FAIL: Could not render \(label) fixture")
          exit(1)
        }
        try await checkImage(fixture, label: label)
      }
      return
    }
    let ocrFailure = AppModel(
      capture: { _, _, _ in image },
      recognize: { _ in throw CheckError.recognition },
      availability: { "Model intentionally unavailable in checks" },
      insights: noInsights, defaults: isolatedDefaults()
    )
    ocrFailure.process(
      displayID: 0, rectangle: CGRect(x: 0, y: 0, width: 700, height: 180), scale: 1)
    try await waitForWork(ocrFailure)
    check("OCR failure keeps capture preview", ocrFailure.preview != nil)
    check(
      "OCR failure is surfaced explicitly",
      ocrFailure.recognitionWarning?.contains("Expected OCR failure") == true)
    check("OCR failure finishes in ready state", ocrFailure.phase == .ready)
    check("OCR failure is not labeled as no readable text", !ocrFailure.showsNoTextMessage)
    check(
      "OCR failure does not fabricate text or answers",
      ocrFailure.recognizedText.isEmpty && ocrFailure.answer.isEmpty)
    ocrFailure.beginSelection()
    ocrFailure.cancelSelection()
    check(
      "Cancelling a new selection preserves the current OCR failure state",
      ocrFailure.recognitionWarning?.contains("Expected OCR failure") == true
        && !ocrFailure.showsNoTextMessage)

    let capturedText = AppModel(
      capture: { _, _, _ in image },
      recognize: { _ in realText },
      availability: { "Model intentionally unavailable in checks" },
      insights: noInsights, defaults: isolatedDefaults()
    )
    capturedText.process(
      displayID: 0, rectangle: CGRect(x: 0, y: 0, width: 700, height: 180), scale: 1)
    try await waitForWork(capturedText)
    check("Unavailable model retains OCR", capturedText.recognizedText == realText)
    check("Unavailable model retains preview", capturedText.preview != nil)
    check("Unavailable model does not fabricate answer", capturedText.answer.isEmpty)
    capturedText.clear()
    check(
      "Clear releases selected content",
      capturedText.preview == nil && capturedText.recognizedText.isEmpty
        && capturedText.answer.isEmpty)

    let captureFailure = AppModel(
      capture: { _, _, _ in throw CheckError.capture },
      recognize: { _ in "" },
      availability: { nil },
      insights: noInsights, defaults: isolatedDefaults()
    )
    captureFailure.process(
      displayID: 0, rectangle: CGRect(x: 0, y: 0, width: 8, height: 8), scale: 1)
    try await waitForWork(captureFailure)
    check("Capture failure is surfaced", captureFailure.errorMessage == "Expected capture failure")
    check(
      "Capture failure leaves idle state",
      captureFailure.phase == .idle && captureFailure.preview == nil)

    let cancellation = AppModel(
      capture: { _, _, _ in
        // Deliberately ignore cancellation to exercise the generation guard,
        // matching framework callbacks that can finish after stop or clear.
        await withCheckedContinuation { continuation in
          DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            continuation.resume(returning: image)
          }
        }
      },
      recognize: { _ in "Should not appear" },
      availability: { "Model intentionally unavailable in checks" },
      insights: noInsights, defaults: isolatedDefaults()
    )
    cancellation.process(
      displayID: 0, rectangle: CGRect(x: 0, y: 0, width: 700, height: 180), scale: 1)
    await Task.yield()
    cancellation.clear()
    try await Task.sleep(for: .milliseconds(200))
    check("Late capture cannot restore cleared image", cancellation.preview == nil)
    check("Late capture cannot replace cleared text", cancellation.recognizedText.isEmpty)
    check(
      "Late capture cannot change idle state",
      cancellation.phase == .idle && cancellation.errorMessage == nil)

    var receivedQuestions: [String] = []
    var receivedContexts: [String] = []
    let chat = AppModel(
      capture: { _, _, _ in image },
      recognize: { _ in realText },
      availability: { nil },
      respond: { _, _, question, context, update in
        receivedQuestions.append(question)
        receivedContexts.append(context)
        update("Draft")
        update("Answer to: \(question)")
      },
      insights: noInsights, defaults: isolatedDefaults()
    )
    chat.process(displayID: 0, rectangle: CGRect(x: 0, y: 0, width: 700, height: 180), scale: 1)
    try await waitForWork(chat)
    check(
      "Initial analysis creates one assistant message",
      chat.messages.count == 1 && chat.messages.first?.role == .assistant)
    check(
      "Initial response completes in place",
      chat.messages.first?.status == .complete && chat.answer.hasPrefix("Answer to:"))
    let initialMessageID = chat.messages.first?.id
    chat.question = "  What does it mean?  "
    chat.ask()
    check("Sending a question immediately enters busy state", chat.phase == .answering)
    check(
      "Question is displayed and composer is cleared",
      chat.messages.dropFirst().first?.content == "What does it mean?" && chat.question.isEmpty)
    chat.ask("This duplicate must not be sent")
    check("A second submission while busy is rejected", chat.messages.count == 3)
    try await waitForWork(chat)
    check(
      "Follow-up retains initial answer",
      chat.messages.first?.id == initialMessageID && chat.messages.count == 3)
    check(
      "Follow-up has distinct user and assistant messages",
      chat.messages.count == 3 && chat.messages[1].role == .user
        && chat.messages[2].role == .assistant)
    check(
      "Streaming updates one message instead of appending chunks",
      chat.messages.last?.content == "Answer to: What does it mean?"
        && chat.messages.last?.status == .complete)
    chat.followsLatestReply = false
    chat.ask("Can you explain that more simply?")
    check("A new question returns scrolling to the latest reply", chat.followsLatestReply)
    try await waitForWork(chat)
    check(
      "Multiple questions and answers remain in history",
      chat.messages.count == 5 && receivedQuestions.count == 3)
    check(
      "Follow-ups receive earlier questions as context",
      receivedContexts.last?.contains("User: What does it mean?") == true)
    check(
      "Follow-ups receive earlier answers as context",
      receivedContexts.last?.contains("Assistant: Answer to: What does it mean?") == true)
    let previousConversationID = chat.conversationID
    let previousMessages = chat.messages
    chat.beginSelection()
    chat.cancelSelection()
    check(
      "Cancelling a new selection preserves the existing chat",
      chat.messages == previousMessages && chat.conversationID == previousConversationID)
    chat.process(displayID: 0, rectangle: CGRect(x: 0, y: 0, width: 700, height: 180), scale: 1)
    check(
      "New selection starts a separate empty chat",
      chat.messages.isEmpty && chat.conversationID != previousConversationID)
    try await waitForWork(chat)
    check(
      "New selection does not send previous chat as context",
      receivedContexts.last?.isEmpty == true && chat.messages.count == 1)
    chat.clear()
    check(
      "Clearing the selection clears chat history",
      chat.messages.isEmpty && chat.answer.isEmpty && chat.preview == nil)

    var boundedContext = ""
    let longReply = String(repeating: "Detailed reply. ", count: 300)
    let boundedChat = AppModel(
      capture: { _, _, _ in image },
      recognize: { _ in realText },
      availability: { nil },
      respond: { _, _, _, context, update in
        boundedContext = context
        update(longReply)
      },
      insights: noInsights, defaults: isolatedDefaults()
    )
    boundedChat.process(
      displayID: 0, rectangle: CGRect(x: 0, y: 0, width: 700, height: 180), scale: 1)
    try await waitForWork(boundedChat)
    boundedChat.ask("Explain further")
    try await waitForWork(boundedChat)
    check("Model conversation context remains bounded", boundedContext.count <= 2000)
    check("Visible history retains full answers", boundedChat.messages.first?.content == longReply)

    var responseAttempts = 0
    var retryContext = ""
    let failedChat = AppModel(
      capture: { _, _, _ in image },
      recognize: { _ in realText },
      availability: { nil },
      respond: { _, _, _, context, update in
        responseAttempts += 1
        if responseAttempts == 1 {
          update("Partial reply")
          throw CheckError.response
        }
        retryContext = context
        update("Successful retry")
      },
      insights: noInsights, defaults: isolatedDefaults()
    )
    failedChat.process(
      displayID: 0, rectangle: CGRect(x: 0, y: 0, width: 700, height: 180), scale: 1)
    try await waitForWork(failedChat)
    check(
      "Failed response is explicitly marked",
      failedChat.messages.first?.status == .failed
        && failedChat.errorMessage == "Expected response failure")
    check("Failed response retains its partial text", failedChat.answer == "Partial reply")
    failedChat.ask("Try again")
    try await waitForWork(failedChat)
    check(
      "Retry keeps failed reply and appends new exchange",
      failedChat.messages.count == 3 && failedChat.messages.first?.status == .failed
        && failedChat.answer == "Successful retry")
    check(
      "Failed reply retains its error details after retry",
      failedChat.messages.first?.errorMessage == "Expected response failure")
    check("Failed partial reply is not treated as completed context", retryContext.isEmpty)

    var interruptedAttempts = 0
    var lateReplyDelivered = false
    let stoppedChat = AppModel(
      capture: { _, _, _ in image },
      recognize: { _ in realText },
      availability: { nil },
      respond: { _, _, _, _, update in
        interruptedAttempts += 1
        if interruptedAttempts == 1 {
          update("Original answer")
          return
        }
        update("Partial follow-up")
        await withCheckedContinuation { continuation in
          DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            continuation.resume()
          }
        }
        update("Late reply that must be ignored")
        lateReplyDelivered = true
      },
      insights: noInsights, defaults: isolatedDefaults()
    )
    stoppedChat.process(
      displayID: 0, rectangle: CGRect(x: 0, y: 0, width: 700, height: 180), scale: 1)
    try await waitForWork(stoppedChat)
    stoppedChat.ask("Tell me more")
    let streamingDeadline = ContinuousClock.now + .seconds(5)
    while stoppedChat.answer != "Partial follow-up" && ContinuousClock.now < streamingDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    check(
      "Cancellation check reaches a real streaming response",
      stoppedChat.messages.last?.status == .streaming && stoppedChat.answer == "Partial follow-up")
    stoppedChat.stop()
    let lateReplyDeadline = ContinuousClock.now + .seconds(5)
    while !lateReplyDelivered && ContinuousClock.now < lateReplyDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    check("Cancellation check receives the late callback", lateReplyDelivered)
    check(
      "Stopping retains previous exchanges and partial reply",
      stoppedChat.messages.count == 3 && stoppedChat.messages.first?.content == "Original answer"
        && stoppedChat.answer == "Partial follow-up")
    check(
      "Stopped response is marked cancelled",
      stoppedChat.messages.last?.status == .cancelled && stoppedChat.phase == .ready)
    check(
      "Late response cannot overwrite stopped chat",
      stoppedChat.errorMessage == nil && stoppedChat.answer != "Late reply that must be ignored")

    // Selection modes and suggestion chips.
    let rect = CGRect(x: 0, y: 0, width: 700, height: 180)
    var insightCalls: [(images: Int, text: String)] = []
    var modeQuestions: [String] = []
    let suggestFirst = AppModel(
      capture: { _, _, _ in image },
      recognize: { _ in realText },
      availability: { nil },
      respond: { _, _, question, _, update in
        modeQuestions.append(question)
        update("Answer to: \(question)")
      },
      insights: { images, text in
        insightCalls.append((images.count, text))
        return SelectionInsights(
          title: "Local text demo",
          suggestions: ["Summarize this text", "Translate it to French", "Draft a reply"])
      },
      defaults: isolatedDefaults()
    )
    check("Answer right away is the default mode", suggestFirst.selectionMode == .answerImmediately)
    suggestFirst.selectionMode = .suggestFirst
    suggestFirst.process(displayID: 0, rectangle: rect, scale: 1)
    try await waitForWork(suggestFirst)
    try await waitUntil { !suggestFirst.suggestionsLoading }
    check("Suggest-first mode does not answer automatically", modeQuestions.isEmpty)
    check("Suggest-first mode shows the prompt card", suggestFirst.showsPromptCard)
    check(
      "Suggest-first mode loads three chips and a title",
      suggestFirst.visibleSuggestions.count == 3
        && suggestFirst.conversationTitle == "Local text demo")
    suggestFirst.ask("Translate it to French")
    try await waitForWork(suggestFirst)
    check("Chip prompt is sent as the question", modeQuestions == ["Translate it to French"])
    check(
      "Used chip is hidden and others remain",
      suggestFirst.visibleSuggestions == ["Summarize this text", "Draft a reply"])
    check("Answer card replaces the prompt card after asking", !suggestFirst.showsPromptCard)
    check("Header uses the generated title", suggestFirst.headerTitle == "Local text demo")
    check("Suggestions are requested once per selection set", insightCalls.count == 1)

    var autoEvents: [String] = []
    let autoMode = AppModel(
      capture: { _, _, _ in image },
      recognize: { _ in realText },
      availability: { nil },
      respond: { _, _, _, _, update in
        autoEvents.append("answer")
        update("Automatic answer")
      },
      insights: { _, _ in
        autoEvents.append("insights")
        return SelectionInsights(title: nil, suggestions: ["Explain the main idea"])
      },
      defaults: isolatedDefaults()
    )
    autoMode.process(displayID: 0, rectangle: rect, scale: 1)
    try await waitForWork(autoMode)
    try await waitUntil { !autoMode.suggestionsLoading }
    check(
      "Answer-right-away mode answers before requesting suggestions",
      autoEvents == ["answer", "insights"])
    check(
      "Follow-up chips appear after the automatic answer", autoMode.visibleSuggestions.count == 1)
    check(
      "Header falls back without a generated title",
      autoMode.conversationTitle == nil && autoMode.headerTitle == "Your selection")

    var receivedImages = 0
    var receivedText = ""
    let captureCount = Counter()
    let multi = AppModel(
      capture: { _, _, _ in image },
      recognize: { _ in "Region \(captureCount.next())" },
      availability: { nil },
      respond: { images, text, _, _, update in
        receivedImages = images.count
        receivedText = text
        update("Combined answer")
      },
      insights: noInsights,
      defaults: isolatedDefaults()
    )
    multi.selectionMode = .suggestFirst
    multi.process(displayID: 0, rectangle: rect, scale: 1)
    try await waitForWork(multi)
    check("Adding is available after the first selection", multi.canAddSelection)
    multi.addSelection(displayID: 0, rectangle: rect, scale: 1)
    check("Adding a selection blocks a second add while capturing", !multi.canAddSelection)
    try await waitForWork(multi)
    check("A second selection is appended", multi.selections.count == 2)
    check("Adding a selection does not answer automatically", multi.messages.isEmpty)
    check(
      "Recognized text labels each selection",
      multi.recognizedText == "Selection 1:\nRegion 1\n\nSelection 2:\nRegion 2")
    multi.ask("Compare these")
    try await waitForWork(multi)
    check("All selected images are sent together", receivedImages == 2)
    check("Combined recognized text is sent", receivedText.contains("Region 2"))
    for _ in 0..<4 {
      multi.addSelection(displayID: 0, rectangle: rect, scale: 1)
      try await waitForWork(multi)
    }
    check(
      "Selections are capped",
      multi.selections.count == AppModel.maximumSelections && !multi.canAddSelection)
    let firstID = multi.selections[0].id
    multi.removeSelection(firstID)
    check(
      "Removing a selection keeps the others",
      multi.selections.count == AppModel.maximumSelections - 1
        && !multi.selections.contains { $0.id == firstID })
    while multi.selections.count > 1 { multi.removeSelection(multi.selections[0].id) }
    multi.removeSelection(multi.selections[0].id)
    check(
      "Removing the last selection clears the chat",
      multi.selections.isEmpty && multi.messages.isEmpty && multi.phase == .idle)

    let failingInsights = AppModel(
      capture: { _, _, _ in image },
      recognize: { _ in realText },
      availability: { nil },
      respond: { _, _, _, _, update in update("Answer") },
      insights: { _, _ in throw CheckError.response },
      defaults: isolatedDefaults()
    )
    failingInsights.process(displayID: 0, rectangle: rect, scale: 1)
    try await waitForWork(failingInsights)
    try await waitUntil { !failingInsights.suggestionsLoading }
    check(
      "Suggestion failures are silent",
      failingInsights.suggestions.isEmpty && failingInsights.errorMessage == nil
        && failingInsights.answer == "Answer")

    var slowInsightsFinished = false
    let staleInsights = AppModel(
      capture: { _, _, _ in image },
      recognize: { _ in realText },
      availability: { nil },
      insights: { _, _ in
        // Ignore cancellation to prove the generation guard drops late results.
        await withCheckedContinuation { continuation in
          DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
        }
        slowInsightsFinished = true
        return SelectionInsights(title: "Stale", suggestions: ["Stale chip"])
      },
      defaults: isolatedDefaults()
    )
    staleInsights.selectionMode = .suggestFirst
    staleInsights.process(displayID: 0, rectangle: rect, scale: 1)
    try await waitForWork(staleInsights)
    check("Suggestions show a loading state", staleInsights.suggestionsLoading)
    staleInsights.clear()
    try await waitUntil { slowInsightsFinished }
    check(
      "Late suggestions cannot repopulate a cleared chat",
      staleInsights.suggestions.isEmpty && staleInsights.conversationTitle == nil
        && !staleInsights.suggestionsLoading)

    // Markdown in replies.
    let markdownReply = ChatMessage(
      role: .assistant, content: "**Heat pumps** move heat.\n- Uses a *compressor*\n- `COP` is 3-4")
    check(
      "Reply Markdown markers are removed for copying and speech",
      markdownReply.plainText == "Heat pumps move heat.\n- Uses a compressor\n- COP is 3-4")
    check(
      "Bold text is rendered as strong emphasis",
      markdownReply.formatted.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    check(
      "An unclosed marker while streaming stays literal",
      ChatMessage(role: .assistant, content: "**Heat").plainText == "**Heat")

    // Card size preferences.
    let sizeDefaults = isolatedDefaults()
    let sized = AppModel(availability: { "Unavailable in checks" }, defaults: sizeDefaults)
    check(
      "Card starts at the default width with automatic height",
      sized.cardWidth == AppModel.defaultCardWidth && sized.userCardHeight == nil
        && !sized.isCustomSize)
    sized.cardWidth = 520
    sized.userCardHeight = 480
    check("Resized card reports a custom size", sized.isCustomSize)
    let reloaded = AppModel(availability: { "Unavailable in checks" }, defaults: sizeDefaults)
    check(
      "Card size persists across launches",
      reloaded.cardWidth == 520 && reloaded.userCardHeight == 480)
    reloaded.resetCardSize()
    let afterReset = AppModel(availability: { "Unavailable in checks" }, defaults: sizeDefaults)
    check(
      "Reset restores default width and automatic height, and persists",
      afterReset.cardWidth == AppModel.defaultCardWidth && afterReset.userCardHeight == nil)
    sizeDefaults.setSetting(5000.0, forKey: "cardWidth")
    sizeDefaults.setSetting(10.0, forKey: "cardHeight")
    let clamped = AppModel(availability: { "Unavailable in checks" }, defaults: sizeDefaults)
    check(
      "Saved sizes are clamped to sensible limits",
      clamped.cardWidth == AppModel.cardWidthRange.upperBound
        && clamped.userCardHeight == AppModel.minimumCardHeight)
    check(
      "Invalid widths fall back to the default",
      AppModel.clampWidth(.nan) == AppModel.defaultCardWidth && AppModel.clampWidth(10) == 340)

    print("\(passed) native checks passed; \(failed) failed.")
    if failed > 0 { exit(1) }
  }

  static func checkImage(_ image: CGImage, label: String) async throws {
    print(
      "\(label): \(image.width)x\(image.height), \(image.bitsPerComponent)bpc, \(image.bitsPerPixel)bpp, bitmapInfo=\(image.bitmapInfo.rawValue)"
    )
    do {
      let text = try await CaptureService.recognizeText(in: image)
      guard !text.isEmpty else {
        print("FAIL: OCR returned no text")
        exit(1)
      }
      print("PASS: OCR recognized \(text.count) characters")
    } catch {
      let error = error as NSError
      print("FAIL: \(error.domain) code \(error.code): \(error.localizedDescription)")
      throw error
    }
  }
}
