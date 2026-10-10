import AppKit
import MagicCursorCore
import SwiftUI

/// Colors sampled from the Googlebook Magic Pointer launch video: a nearly
/// black navy answer card with a blue edge glow, navy glass prompt surfaces,
/// and a Gemini-style spectrum for sparks and the thinking shimmer.
enum Palette {
  static let cardFill = Color(red: 0.016, green: 0.020, blue: 0.043)
  /// Muted navy sampled at the launch-video card edge (#1B3D66); the glow
  /// fades from this to the fill within about 20 points and never extends
  /// outside the card.
  static let edgeGlow = Color(red: 0.106, green: 0.239, blue: 0.400)
  static let rim = Color(red: 0.145, green: 0.275, blue: 0.450)
  static let glassTop = Color(red: 0.14, green: 0.20, blue: 0.33)
  static let glassBottom = Color(red: 0.07, green: 0.10, blue: 0.19)
  static let field = Color(red: 0.067, green: 0.090, blue: 0.145)
  static let fieldBorder = Color.white.opacity(0.07)
  static let bubble = Color(red: 0.11, green: 0.15, blue: 0.24)
  static let control = Color(red: 0.17, green: 0.21, blue: 0.29)
  static let text = Color(red: 0.93, green: 0.94, blue: 0.97)
  static let secondaryText = Color(red: 0.72, green: 0.76, blue: 0.84)
  static let tertiaryText = Color(red: 0.50, green: 0.55, blue: 0.65)
  static let accent = Color(red: 0.54, green: 0.71, blue: 0.97)
  static let onAccent = Color(red: 0.02, green: 0.10, blue: 0.27)
  static let warning = Color(red: 0.99, green: 0.84, blue: 0.39)
  static let error = Color(red: 0.95, green: 0.55, blue: 0.51)
  /// RGB stops of the spectrum, kept as plain values so drawing closures can
  /// use them off the main actor.
  static let spectrum: [(Double, Double, Double)] = [
    (0.278, 0.533, 0.976), (0.608, 0.447, 0.949), (0.937, 0.408, 0.533),
    (0.976, 0.722, 0.290), (0.235, 0.769, 0.541),
  ]
  static let blueOnly: [(Double, Double, Double)] = [(0.30, 0.50, 0.95), (0.38, 0.60, 1.0)]
  static let spark = LinearGradient(
    colors: spectrum.prefix(4).map { Color(red: $0.0, green: $0.1, blue: $0.2) },
    startPoint: .topLeading, endPoint: .bottomTrailing)
}

enum PanelLayout {
  /// Transparent room around the card so its glow and shadow are not clipped.
  static let shadowMargin: CGFloat = 26
  static let topMargin: CGFloat = 12
  static let bottomMargin: CGFloat = 36
  static let cornerRadius: CGFloat = 30
  /// Googlebook's answer card is a compact portrait card, so an unresized
  /// card stops growing here even when the display has more room.
  static let automaticCardMaxHeight: CGFloat = 640

  static func windowWidth(for cardWidth: CGFloat) -> CGFloat { cardWidth + shadowMargin * 2 }
}

private struct ConversationScrollMetrics: Equatable, Sendable {
  let offset: CGFloat
  let contentHeight: CGFloat
  let atBottom: Bool
}

/// The floating card, following Googlebook Magic Pointer: a frosted glass
/// prompt card with selection thumbnails until the first question, then a
/// dark answer card with a glowing edge, a title header, and an Ask field.
/// Suggestion chips float below the card in both states.
struct AssistantPanel: View {
  @ObservedObject var model: AppModel

  private var isPrompt: Bool {
    model.showsPromptCard || (model.phase == .capturing && model.messages.isEmpty)
  }
  private var isWelcome: Bool { model.selections.isEmpty && model.phase != .capturing }

  var body: some View {
    // The window is resized to this measured stack, so it covers only the card
    // and pills. A full-height transparent window would swallow clicks below.
    VStack(alignment: .leading, spacing: 10) {
      card(maxHeight: max(220, model.panelMaxHeight - suggestionReserve))
      if showsSuggestionArea { suggestions }
    }
    .frame(width: model.cardWidth)
    .padding(.horizontal, PanelLayout.shadowMargin)
    .padding(.top, PanelLayout.topMargin)
    .padding(.bottom, PanelLayout.bottomMargin)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.height
    } action: { height in
      model.panelContentHeight = height
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .foregroundStyle(Palette.text)
    .tint(Palette.accent)
    .environment(\.colorScheme, .dark)
    .animation(.spring(response: 0.38, dampingFraction: 0.86), value: isPrompt)
    .animation(.easeOut(duration: 0.2), value: model.visibleSuggestions)
  }

  // MARK: Card

  // A flexible maxHeight frame would expand to the limit, so size the scroll
  // area explicitly from measured content and chrome. After the user resizes
  // the answer card, it keeps that height instead of hugging its content.
  private func card(maxHeight: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous)
    let showsComposer = !isWelcome
    let isAnswer = !isPrompt && !isWelcome
    let chrome = model.cardHeaderHeight + (showsComposer ? model.cardComposerHeight : 0)
    let hasScroll = !isPrompt || hasPromptExtras
    let scrollHeight: CGFloat
    if isAnswer, let fixed = model.userCardHeight {
      scrollHeight = max(1, min(fixed, maxHeight) - chrome)
    } else {
      let limit = min(maxHeight, PanelLayout.automaticCardMaxHeight)
      scrollHeight = max(1, min(model.cardContentHeight, limit - chrome))
    }
    return VStack(spacing: 0) {
      header.onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.height
      } action: { height in
        model.cardHeaderHeight = height
      }
      if isPrompt {
        promptComposer.measuredComposer(model)
        if hasScroll { conversation.frame(height: scrollHeight) }
      } else {
        conversation.frame(height: scrollHeight)
        if showsComposer { answerComposer.measuredComposer(model) }
      }
    }
    .background {
      ZStack(alignment: .bottom) {
        if isPrompt { GlassCardBackground() } else { GlowCardBackground() }
        if model.phase.isBusy {
          ThinkingGlow()
            .frame(height: 96)
            .transition(.opacity)
        }
        WindowDragArea()
      }
      .clipShape(shape)
    }
    .overlay(shape.strokeBorder(Palette.rim.opacity(isPrompt ? 0.7 : 0.55), lineWidth: 1))
    .clipShape(shape)
    .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.height
    } action: { height in
      model.measuredCardHeight = height
    }
    .overlay { ResizeHandles(model: model, allowsHeight: isAnswer) }
    .animation(.easeInOut(duration: 0.3), value: model.phase.isBusy)
  }

  @ViewBuilder private var header: some View {
    if isWelcome {
      appHeader
    } else if isPrompt {
      promptHeader
    } else {
      answerHeader
    }
  }

  private var appHeader: some View {
    HStack(spacing: 10) {
      Image(nsImage: MagicCursorArt.glyph)
        .resizable()
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
      Text("Magic Cursor").font(.system(size: 15, weight: .semibold))
      Spacer(minLength: 8)
      settingsButton
      iconButton("xmark", label: "Close", action: model.closePanel)
    }
    .padding(.leading, 20)
    .padding(.trailing, 12)
    .padding(.top, 14)
    .padding(.bottom, 2)
  }

  /// Selection thumbnails and the add tile, like Magic Pointer's prompt card.
  private var promptHeader: some View {
    HStack(alignment: .top, spacing: 10) {
      ForEach(model.selections) { selection in
        thumbnail(selection, height: 72, removable: true)
      }
      if model.phase == .capturing {
        placeholderTile(height: 72)
      } else if model.canAddSelection {
        addTile(height: 72)
      }
      Spacer(minLength: 4)
      settingsButton
      iconButton("xmark", label: "Close", action: model.closePanel)
    }
    .padding(.leading, 16)
    .padding(.trailing, 10)
    .padding(.top, 16)
  }

  private var answerHeader: some View {
    HStack(spacing: 8) {
      Image(systemName: "sparkle")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Palette.spark)
        .symbolEffect(.pulse, isActive: model.phase.isBusy)
        .accessibilityHidden(true)
      Text(model.headerTitle)
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 6)
      if let latest = model.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) {
        let speaking = model.speakingMessageID == latest.id
        iconButton(
          speaking ? "speaker.slash.fill" : "speaker.wave.2.fill",
          label: speaking ? "Stop reading" : "Read aloud", active: speaking
        ) {
          model.toggleSpeech(latest)
        }
      }
      glyphButton(label: "New selection (starts a new chat)", action: model.selectRegion)
      settingsButton
      iconButton("xmark", label: "Close", action: model.closePanel)
    }
    .padding(.leading, 20)
    .padding(.trailing, 10)
    .padding(.top, 14)
    .padding(.bottom, 4)
  }

  private var settingsButton: some View {
    iconButton("gearshape", label: "Settings", active: model.showSettings) {
      model.showSettings.toggle()
    }
  }

  private func iconButton(
    _ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13.5, weight: .medium))
        .frame(width: 30, height: 30)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(active ? Palette.accent : Palette.secondaryText)
    .help(label)
    .accessibilityLabel(label)
  }

  /// The app's own pointer-and-spark mark for starting a new selection. A
  /// square viewfinder here read as a window maximize button.
  private func glyphButton(label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(nsImage: MagicCursorArt.statusIcon)
        .renderingMode(.template)
        .resizable()
        .frame(width: 17, height: 17)
        .frame(width: 30, height: 30)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(Palette.secondaryText)
    .help(label)
    .accessibilityLabel(label)
  }

  // MARK: Thumbnails

  private func thumbnail(_ selection: CapturedSelection, height: CGFloat, removable: Bool)
    -> some View
  {
    let shape = RoundedRectangle(cornerRadius: height * 0.24, style: .continuous)
    let size = selection.preview.size
    let aspect = size.height > 0 ? size.width / size.height : 1
    let single = model.selections.count == 1
    let width = single ? min(170, max(height, height * aspect)) : height
    return Image(nsImage: selection.preview)
      .resizable()
      .scaledToFill()
      .frame(width: width, height: height)
      .clipShape(shape)
      .overlay(shape.strokeBorder(Color.white.opacity(0.12)))
      .overlay(alignment: .topTrailing) {
        if removable {
          Button {
            model.removeSelection(selection.id)
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 8.5, weight: .bold))
              .foregroundStyle(.white)
              .frame(width: 20, height: 20)
              .background(Color.black.opacity(0.65), in: Circle())
          }
          .buttonStyle(.plain)
          .padding(5)
          .help("Remove this selection")
          .accessibilityLabel("Remove this selection")
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Selected screen region")
  }

  private func addTile(height: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: height * 0.24, style: .continuous)
    return Button(action: model.addRegion) {
      Image(systemName: "plus")
        .font(.system(size: height * 0.3, weight: .light))
        .foregroundStyle(Palette.secondaryText)
        .frame(width: height, height: height)
        .overlay(
          shape.strokeBorder(
            Palette.secondaryText.opacity(0.5), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
        )
        .contentShape(shape)
    }
    .buttonStyle(.plain)
    .help("Add another selection")
    .accessibilityLabel("Add another selection")
  }

  private func placeholderTile(height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: height * 0.24, style: .continuous)
      .fill(Color.white.opacity(0.06))
      .frame(width: height, height: height)
      .overlay {
        Image(systemName: "sparkle")
          .font(.system(size: 18))
          .foregroundStyle(Palette.spark)
          .symbolEffect(.pulse)
      }
      .accessibilityLabel("Reading your selection")
  }

  // MARK: Composers

  private var promptComposer: some View {
    let unavailable = model.modelMessage != nil
    let disabled = model.phase.isBusy || unavailable
    let empty = model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let placeholder =
      unavailable
      ? "Apple Intelligence is unavailable"
      : model.phase == .capturing
        ? "Reading your selection..."
        : model.selections.count > 1 ? "Ask about these selections" : "Ask about this selection"
    return HStack(alignment: .bottom, spacing: 10) {
      TextField(placeholder, text: $model.question, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 16))
        .lineLimit(1...5)
        .padding(.vertical, 6)
        .onSubmit { model.ask() }
        .disabled(disabled)
        .accessibilityLabel("Question about the selection")
      sendButton(disabled: disabled || empty, circled: false)
    }
    .padding(.leading, 20)
    .padding(.trailing, 12)
    .padding(.top, 12)
    .padding(.bottom, 16)
  }

  private var answerComposer: some View {
    let unavailable = model.modelMessage != nil
    let disabled = model.phase.isBusy || unavailable
    let empty = model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return HStack(alignment: .center, spacing: 6) {
      Button(action: model.addRegion) {
        Image(systemName: "plus")
          .font(.system(size: 16, weight: .regular))
          .frame(width: 32, height: 32)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(model.canAddSelection ? Palette.text : Palette.tertiaryText)
      .disabled(!model.canAddSelection)
      .help("Add another selection")
      .accessibilityLabel("Add another selection")
      TextField(
        unavailable ? "Apple Intelligence is unavailable" : "Ask a follow-up",
        text: $model.question, axis: .vertical
      )
      .textFieldStyle(.plain)
      .font(.system(size: 15))
      .lineLimit(1...4)
      .padding(.vertical, 8)
      .onSubmit { model.ask() }
      .disabled(disabled)
      .accessibilityLabel("Follow-up question")
      sendButton(disabled: disabled || empty, circled: true)
    }
    .padding(.leading, 8)
    .padding(.trailing, 6)
    .padding(.vertical, 5)
    .background(Palette.field, in: Capsule())
    .overlay(Capsule().strokeBorder(Palette.fieldBorder))
    .padding(.horizontal, 12)
    .padding(.top, 6)
    .padding(.bottom, 12)
  }

  private func sendButton(disabled: Bool, circled: Bool) -> some View {
    Button {
      model.ask()
    } label: {
      Image(systemName: "paperplane.fill")
        .font(.system(size: circled ? 13 : 16))
        .rotationEffect(.degrees(45))
        .offset(x: -1)
        .frame(width: 36, height: 36)
        .background(circled ? Palette.control : .clear, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(disabled ? Palette.tertiaryText.opacity(0.6) : Palette.text)
    .disabled(disabled)
    .keyboardShortcut(.return, modifiers: .command)
    .accessibilityLabel("Send question")
  }

  // MARK: Conversation

  private var hasPromptExtras: Bool {
    model.errorMessage != nil || model.recognitionWarning != nil || model.modelMessage != nil
      || !model.screenPermission || model.showSettings
  }

  private var conversation: some View {
    ScrollViewReader { proxy in
      conversationScrollView
        .onChange(of: model.messages.count) { previous, current in
          if current > previous {
            model.followsLatestReply = true
            scrollToLatest(using: proxy)
          }
        }
        .onChange(of: model.messages.last?.content) { _, _ in
          if model.followsLatestReply { scrollToLatest(using: proxy) }
        }
        .onChange(of: model.phase) { _, phase in
          if phase == .ready && model.followsLatestReply { scrollToLatest(using: proxy) }
        }
    }
  }

  @ViewBuilder private var conversationScrollView: some View {
    let scrollView = ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if isWelcome {
          welcome
        } else if !isPrompt {
          answerContent
        }
        if !isPrompt || model.modelMessage != nil { recognizedTextSection }
        notices
        if model.showSettings { settings }
        Color.clear.frame(height: 1).id("conversation-bottom")
      }
      .padding(.horizontal, 20)
      .padding(.top, isPrompt ? 2 : 8)
      // The stack spacing before the bottom marker already adds 16 points.
      .padding(.bottom, 2)
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.height
      } action: { height in
        model.cardContentHeight = height
      }
    }
    .scrollIndicators(.automatic)
    // Soften the edge where scrolled text passes under the header.
    .mask(
      VStack(spacing: 0) {
        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
          .frame(height: 10)
        Color.black
      }
    )
    .id(model.conversationID)

    if #available(macOS 15, *) {
      scrollView
        .onScrollGeometryChange(for: ConversationScrollMetrics.self) { geometry in
          ConversationScrollMetrics(
            offset: geometry.contentOffset.y,
            contentHeight: geometry.contentSize.height,
            atBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 2)
        } action: { previous, current in
          if model.isUserScrolling {
            model.followsLatestReply = false
          } else if current.atBottom {
            model.followsLatestReply = true
          } else if current.offset < previous.offset - 1
            && current.contentHeight >= previous.contentHeight
          {
            model.followsLatestReply = false
          }
        }
        .onScrollPhaseChange { previous, current, context in
          let wasUserScrolling = previous.isScrolling && previous != .animating
          model.isUserScrolling = current.isScrolling && current != .animating
          if model.isUserScrolling {
            model.followsLatestReply = false
          } else if wasUserScrolling {
            model.followsLatestReply =
              context.geometry.visibleRect.maxY >= context.geometry.contentSize.height - 2
          }
        }
    } else {
      scrollView
    }
  }

  private func scrollToLatest(using proxy: ScrollViewProxy) {
    // Streaming can publish before the new text has been laid out. Scroll on
    // the next UI turn, and re-check the user's intent before moving the view.
    DispatchQueue.main.async {
      if model.followsLatestReply { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
    }
  }

  @ViewBuilder private var answerContent: some View {
    HStack(spacing: 8) {
      ForEach(model.selections) { selection in
        thumbnail(selection, height: 52, removable: false)
      }
      if model.phase == .capturing { placeholderTile(height: 52) }
    }
    ForEach(model.messages) { message in
      chatMessage(message)
    }
    Text("Generated on your Mac. Answers can be wrong.")
      .font(.system(size: 11))
      .foregroundStyle(Palette.tertiaryText)
  }

  @ViewBuilder private func chatMessage(_ message: ChatMessage) -> some View {
    if message.role == .user {
      HStack {
        Spacer(minLength: 48)
        Text(message.content)
          .font(.system(size: 14.5))
          .lineSpacing(3)
          .textSelection(.enabled)
          .padding(.horizontal, 15)
          .padding(.vertical, 10)
          .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Your question")
    } else {
      VStack(alignment: .leading, spacing: 10) {
        if message.content.isEmpty && message.status == .streaming {
          Text("Thinking...")
            .font(.system(size: 15))
            .foregroundStyle(Palette.secondaryText)
        } else if !message.content.isEmpty {
          Text(message.formatted)
            .font(.system(size: 15))
            .lineSpacing(4.5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if message.status == .cancelled {
          Text("Response stopped.")
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.tertiaryText)
        } else if message.status == .failed {
          Text(message.errorMessage ?? "Response could not be completed.")
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.error)
        }
        messageActions(message)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Assistant reply")
    }
  }

  @ViewBuilder private func messageActions(_ message: ChatMessage) -> some View {
    if message.status == .streaming {
      Button(action: model.stop) {
        Label("Stop", systemImage: "stop.fill")
          .font(.system(size: 11.5, weight: .medium))
          .padding(.horizontal, 11)
          .padding(.vertical, 6)
          .background(Palette.control, in: Capsule())
      }
      .buttonStyle(.plain)
      .foregroundStyle(Palette.secondaryText)
    } else if !message.content.isEmpty {
      let speaking = model.speakingMessageID == message.id
      HStack(spacing: 16) {
        Button {
          model.copy(message.plainText)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .help("Copy this answer")
        .accessibilityLabel("Copy this answer")
        Button {
          model.toggleSpeech(message)
        } label: {
          Image(systemName: speaking ? "speaker.slash" : "speaker.wave.2")
        }
        .help(speaking ? "Stop reading" : "Read this answer aloud")
        .accessibilityLabel(speaking ? "Stop reading" : "Read this answer aloud")
      }
      .buttonStyle(.plain)
      .font(.system(size: 12.5))
      .foregroundStyle(speaking ? Palette.accent : Palette.tertiaryText)
    }
  }

  @ViewBuilder private var recognizedTextSection: some View {
    if !model.recognizedText.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
          Button {
            model.showRecognizedText.toggle()
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "text.viewfinder")
              Text("Recognized text")
              Image(systemName: model.showRecognizedText ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
            }
          }
          .buttonStyle(.plain)
          Spacer()
          Button {
            model.copy(model.recognizedText)
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.plain)
          .help("Copy recognized text")
          .accessibilityLabel("Copy recognized text")
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.tertiaryText)
        if model.showRecognizedText {
          Text(model.recognizedText)
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.secondaryText)
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
      }
    } else if model.showsNoTextMessage && !isPrompt {
      Text("No readable text in this selection.")
        .font(.system(size: 12))
        .foregroundStyle(Palette.tertiaryText)
    }
  }

  @ViewBuilder private var notices: some View {
    if let message = model.errorMessage, model.messages.last?.errorMessage != message {
      notice(message, symbol: "exclamationmark.triangle.fill", color: Palette.error)
    }
    if let message = model.recognitionWarning {
      notice(message, symbol: "text.viewfinder", color: Palette.warning)
    }
    if !model.screenPermission { permissionCard }
    if let message = model.modelMessage {
      notice(message, symbol: "cpu", color: Palette.accent)
    }
  }

  // MARK: Welcome, notices, settings

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 18) {
      ZStack {
        Circle()
          .fill(Palette.spark)
          .opacity(0.22)
          .blur(radius: 24)
          .frame(width: 100, height: 100)
        Image(nsImage: MagicCursorArt.glyph)
          .resizable()
          .frame(width: 72, height: 72)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 4)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text("Shake, select, ask")
          .font(.system(size: 22, weight: .semibold))
        Text(
          "Give your pointer a quick back-and-forth shake, then drag over anything on screen to ask about it."
        )
        .font(.system(size: 14))
        .foregroundStyle(Palette.secondaryText)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 12) {
        tip("arrow.left.and.right", "Three quick back-and-forth shakes")
        tip("viewfinder", "Drag around text, an image, or a chart")
        tip("plus", "Add more selections to ask about them together")
      }
      Button {
        if model.screenPermission { model.selectRegion() } else { model.requestPermission() }
      } label: {
        Label(
          model.screenPermission ? "Select something" : "Allow screen capture",
          systemImage: model.screenPermission ? "viewfinder" : "rectangle.dashed.badge.record"
        )
        .font(.system(size: 14, weight: .semibold))
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(Palette.accent, in: Capsule())
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .foregroundStyle(Palette.onAccent)
      .accessibilityIdentifier(model.screenPermission ? "select-region" : "allow-screen-capture")
      HStack(spacing: 6) {
        Image(systemName: "lock.fill").font(.system(size: 10))
        Text("Private. Runs on your Mac.")
        Spacer()
        Circle()
          .fill(model.shakeEnabled ? Color.green.opacity(0.75) : Palette.tertiaryText)
          .frame(width: 6, height: 6)
        Text(model.shakeEnabled ? "Shake ready" : "Shake paused")
      }
      .font(.system(size: 11))
      .foregroundStyle(Palette.tertiaryText)
    }
  }

  private func tip(_ symbol: String, _ text: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Palette.accent)
        .frame(width: 30, height: 30)
        .background(Palette.bubble, in: Circle())
      Text(text)
        .font(.system(size: 13))
        .foregroundStyle(Palette.secondaryText)
    }
  }

  private var permissionCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Allow screen capture", systemImage: "rectangle.dashed.badge.record")
        .font(.system(size: 13, weight: .semibold))
      Text(
        "macOS needs Screen Recording permission to read the region you select. Nothing is recorded or uploaded."
      )
      .font(.system(size: 12))
      .foregroundStyle(Palette.secondaryText)
      .lineSpacing(3)
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 14) {
        Button(action: model.requestPermission) {
          Text("Allow")
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Palette.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.onAccent)
        Button("Check again", action: model.refreshAvailability)
          .buttonStyle(.plain)
          .font(.system(size: 12))
          .foregroundStyle(Palette.accent)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("SETTINGS")
        .font(.system(size: 10, weight: .semibold))
        .tracking(1.2)
        .foregroundStyle(Palette.tertiaryText)
      settingGroup("After selecting") {
        Picker("After selecting", selection: $model.selectionMode) {
          ForEach(SelectionMode.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text(
          model.selectionMode == .answerImmediately
            ? "Explains the selection immediately, then suggests follow-ups."
            : "Shows suggestions first and waits for your question, like Googlebook."
        )
        .font(.system(size: 11))
        .foregroundStyle(Palette.tertiaryText)
        .fixedSize(horizontal: false, vertical: true)
      }
      Toggle("Shake to select", isOn: $model.shakeEnabled)
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 13))
      settingGroup("Shake sensitivity") {
        Picker("Shake sensitivity", selection: $model.sensitivity) {
          ForEach(ShakeDetector.Sensitivity.allCases, id: \.self) { value in
            Text(value.title).tag(value)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text("Gentle needs less movement. Deliberate avoids accidental activation.")
          .font(.system(size: 11))
          .foregroundStyle(Palette.tertiaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 16) {
        if model.isCustomSize {
          Button("Reset card size", action: model.resetCardSize)
            .help("Restore the default width and let the card fit its content")
        }
        if !model.selections.isEmpty {
          Button("Clear selection and chat", action: model.clear)
        }
        Spacer(minLength: 0)
        Button("All settings…", action: model.openSettings)
          .help("Open the Magic Cursor Settings window")
      }
      .buttonStyle(.plain)
      .font(.system(size: 12))
      .foregroundStyle(Palette.accent)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private func settingGroup<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 13))
      content()
    }
  }

  private func notice(_ text: String, symbol: String, color: Color) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol).foregroundStyle(color)
      Text(text)
        .foregroundStyle(Palette.secondaryText)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.system(size: 12.5))
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  // MARK: Suggestions

  private var copyTextFallback: Bool {
    model.modelMessage != nil && !model.recognizedText.isEmpty
  }

  private var showsSuggestionArea: Bool {
    guard !model.selections.isEmpty, model.phase != .capturing else { return false }
    return !model.visibleSuggestions.isEmpty || model.suggestionsLoading || copyTextFallback
  }

  private var suggestionReserve: CGFloat {
    guard showsSuggestionArea else { return 0 }
    let count =
      model.suggestionsLoading ? 3 : model.visibleSuggestions.count + (copyTextFallback ? 1 : 0)
    return CGFloat(count) * 50 + 10
  }

  private var suggestions: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.suggestionsLoading && model.visibleSuggestions.isEmpty {
        ForEach([210, 170, 230] as [CGFloat], id: \.self) { width in
          ShimmerChip(width: width)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading suggestions")
      } else {
        ForEach(model.visibleSuggestions, id: \.self) { suggestion in
          chip(suggestion, symbol: "sparkle", disabled: model.phase.isBusy) {
            model.ask(suggestion)
          }
        }
      }
      if copyTextFallback {
        chip("Copy recognized text", symbol: "doc.on.doc", disabled: false) {
          model.copy(model.recognizedText)
        }
      }
    }
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  private func chip(
    _ title: String, symbol: String, disabled: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: symbol)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(Palette.spark)
        Text(title)
          .font(.system(size: 14))
          .lineLimit(1)
      }
      .padding(.horizontal, 16)
      .frame(height: 42)
      .background(GlassPillBackground())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .foregroundStyle(Palette.text)
    .opacity(disabled ? 0.55 : 1)
    .disabled(disabled)
    .help(title)
  }
}

extension View {
  fileprivate func measuredComposer(_ model: AppModel) -> some View {
    onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.height
    } action: { height in
      model.cardComposerHeight = height
    }
  }
}

// MARK: - Surfaces

/// The answer card surface: nearly black navy with a thin, muted inner edge
/// glow. The stroke is centered on the clipped edge, so only its inner half
/// shows, fading inward through the blur.
private struct GlowCardBackground: View {
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous)
    ZStack {
      shape.fill(Palette.cardFill.opacity(0.97))
      shape
        .stroke(Palette.edgeGlow, lineWidth: 14)
        .blur(radius: 9)
    }
  }
}

/// The prompt card surface: real backdrop blur tinted navy, with a faint
/// navy edge and a quiet halftone fringe along the bottom.
private struct GlassCardBackground: View {
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous)
    ZStack(alignment: .bottom) {
      BackdropBlur(cornerRadius: PanelLayout.cornerRadius)
      LinearGradient(
        colors: [Palette.glassTop.opacity(0.78), Palette.glassBottom.opacity(0.86)],
        startPoint: .top, endPoint: .bottom)
      shape
        .stroke(Palette.edgeGlow, lineWidth: 12)
        .blur(radius: 7)
        .opacity(0.8)
      HalftoneEdge(palette: Palette.blueOnly, time: nil)
        .frame(height: 24)
        .opacity(0.3)
    }
  }
}

private struct GlassPillBackground: View {
  var body: some View {
    Capsule()
      .fill(
        LinearGradient(
          colors: [Palette.glassTop.opacity(0.96), Palette.glassBottom.opacity(0.96)],
          startPoint: .top, endPoint: .bottom)
      )
      .overlay(Capsule().strokeBorder(Palette.rim.opacity(0.6)))
      .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
  }
}

private struct ShimmerChip: View {
  let width: CGFloat

  var body: some View {
    TimelineView(.animation) { timeline in
      let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)
      GlassPillBackground()
        .overlay {
          LinearGradient(
            colors: [.clear, Color.white.opacity(0.12), .clear],
            startPoint: .leading, endPoint: .trailing
          )
          .frame(width: 80)
          .offset(x: (phase / 1.6) * (width + 80) - width / 2 - 40)
          .clipShape(Capsule())
        }
        .frame(width: width, height: 42)
    }
  }
}

/// Lets the card's empty areas drag the window. NSHostingView does not report
/// SwiftUI content as window background, so `isMovableByWindowBackground`
/// alone never moves this panel. Controls and selectable text sit above this
/// view and keep their own clicks; only otherwise empty areas reach it.
private struct WindowDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
      window?.performDrag(with: event)
    }
  }
}

/// Real behind-window blur. SwiftUI materials blend within the window, which
/// shows nothing through this transparent panel. A mask image, not SwiftUI
/// clipping, shapes the blur because the window server applies it.
private struct BackdropBlur: NSViewRepresentable {
  let cornerRadius: CGFloat

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    view.maskImage = Self.mask(radius: cornerRadius)
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}

  private static func mask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: CGSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}

// MARK: - Thinking shimmer

/// The rainbow halftone shimmer that moves along the bottom of the card while
/// Magic Pointer is thinking.
private struct ThinkingGlow: View {
  var body: some View {
    TimelineView(.animation) { timeline in
      let time = timeline.date.timeIntervalSinceReferenceDate
      ZStack(alignment: .bottom) {
        LinearGradient(
          colors: Palette.spectrum.map { Color(red: $0.0, green: $0.1, blue: $0.2) },
          startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 22)
        .blur(radius: 20)
        .opacity(0.32 + 0.1 * sin(time * 2))
        HalftoneEdge(palette: Palette.spectrum, time: time)
          .opacity(0.8)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Dots that grow and brighten toward the bottom edge. With a time value, a
/// wave and the colors drift sideways; without one, the pattern is static.
private struct HalftoneEdge: View {
  let palette: [(Double, Double, Double)]
  let time: Double?

  var body: some View {
    let palette = palette
    let time = time
    Canvas { context, size in
      let spacing: CGFloat = 6
      let rows = max(1, Int(size.height / spacing))
      for row in 0..<rows {
        let fade = 1 - Double(row) / Double(rows)
        let y = size.height - CGFloat(row) * spacing - spacing / 2
        var x: CGFloat = row.isMultiple(of: 2) ? spacing / 2 : spacing
        while x < size.width {
          let position = Double(x / max(size.width, 1))
          let wave = time.map { 0.5 + 0.5 * sin(position * 9.4 - $0 * 2.4) } ?? 1
          let alpha = fade * fade * (0.25 + 0.75 * wave)
          let radius = 0.6 + 0.9 * fade * wave
          let color = Self.color(palette, at: position + (time ?? 0) * 0.08)
          context.fill(
            Path(
              ellipseIn: CGRect(
                x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
            with: .color(color.opacity(alpha)))
          x += spacing
        }
      }
    }
  }

  private static func color(_ palette: [(Double, Double, Double)], at position: Double) -> Color {
    guard palette.count > 1 else {
      let only = palette.first ?? (1, 1, 1)
      return Color(red: only.0, green: only.1, blue: only.2)
    }
    let wrapped = position - position.rounded(.down)
    let scaled = wrapped * Double(palette.count)
    let index = Int(scaled) % palette.count
    let next = (index + 1) % palette.count
    let t = scaled - scaled.rounded(.down)
    let a = palette[index]
    let b = palette[next]
    return Color(
      red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
  }
}
