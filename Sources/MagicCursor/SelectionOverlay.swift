import AppKit
import MagicCursorCore

@MainActor
final class SelectionWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class SelectionOverlay: NSView {
  var onSelection: (CGRect) -> Void = { _ in }
  var onCancel: () -> Void = {}
  /// Hint shown before dragging; differs when adding to an existing selection.
  var idleMessage = "Drag to select anything"
  private var anchor: CGPoint?
  private var pointer: CGPoint = .zero
  private var tracking: NSTrackingArea?
  private let hint = HintPillView()
  private lazy var cancelButton = makeCancelButton()

  private var currentCursor: NSCursor {
    anchor == nil ? MagicCursorArt.pointerCursor : MagicCursorArt.crosshairCursor
  }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    setAccessibilityLabel("Screen region selection")
    setAccessibilityHelp("Drag over a region to ask about it. Press Escape or Cancel to exit.")
    cancelButton.frame = CGRect(x: bounds.maxX - 60, y: bounds.maxY - 84, width: 36, height: 36)
    cancelButton.autoresizingMask = [.minXMargin, .minYMargin]
    addSubview(cancelButton)
    addSubview(hint)
    pointer = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    hint.message = idleMessage
    layoutHint()
    currentCursor.set()
  }

  func restoreCursor() {
    NSCursor.arrow.set()
  }

  override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
      owner: self)
    addTrackingArea(area)
    tracking = area
    super.updateTrackingAreas()
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: currentCursor) }
  override func cursorUpdate(with event: NSEvent) { currentCursor.set() }
  override func mouseMoved(with event: NSEvent) { move(event) }

  override func mouseDown(with event: NSEvent) {
    anchor = convert(event.locationInWindow, from: nil)
    hint.message = "Release to ask"
    cursorDidChange()
    move(event)
  }

  override func mouseDragged(with event: NSEvent) { move(event) }

  override func mouseUp(with event: NSEvent) {
    move(event)
    guard let anchor,
      let rectangle = SelectionGeometry.rectangle(from: anchor, to: pointer, in: bounds)
    else {
      self.anchor = nil
      hint.message = idleMessage
      cursorDidChange()
      layoutHint()
      needsDisplay = true
      return
    }
    onSelection(rectangle)
  }

  override func rightMouseDown(with event: NSEvent) { onCancel() }
  @objc private func cancelSelection() { onCancel() }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { onCancel() }
  }

  private func cursorDidChange() {
    window?.invalidateCursorRects(for: self)
    currentCursor.set()
  }

  private func move(_ event: NSEvent) {
    pointer = convert(event.locationInWindow, from: nil)
    currentCursor.set()
    layoutHint()
    if anchor != nil { needsDisplay = true }
  }

  /// Keeps the hint beside the pointer, flipping to the other side near the
  /// display edges so it never sits under the pointer or off screen.
  private func layoutHint() {
    let size = hint.preferredSize
    var origin = CGPoint(x: pointer.x + 22, y: pointer.y - 30 - size.height)
    if origin.x + size.width > bounds.maxX - 12 { origin.x = pointer.x - 22 - size.width }
    if origin.y < bounds.minY + 12 { origin.y = pointer.y + 26 }
    origin.x = max(bounds.minX + 12, origin.x)
    hint.frame = CGRect(origin: origin, size: size).integral
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let selected = anchor.flatMap {
      SelectionGeometry.rectangle(from: $0, to: pointer, in: bounds)
    }
    guard let selected else {
      // Fully transparent pixels let clicks fall through to the windows below,
      // so keep a barely visible tint to make the whole display selectable.
      context.setFillColor(CGColor(gray: 0, alpha: 0.03))
      context.fill(bounds)
      return
    }
    let shape = CGPath(
      roundedRect: selected, cornerWidth: 12, cornerHeight: 12, transform: nil)
    context.addRect(bounds)
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0, alpha: 0.16))
    context.fillPath(using: .evenOdd)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    MagicCursorArt.drawHalftone(in: selected, context: context)
    context.restoreGState()

    let scale = window?.backingScaleFactor ?? 2
    guard
      let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: MagicCursorArt.spectrum.map(\.cgColor) as CFArray, locations: nil)
    else { return }
    context.saveGState()
    // Shadow blur is in device pixels, so scale it for Retina displays.
    context.setShadow(
      offset: .zero, blur: 8 * scale,
      color: MagicCursorArt.glowBlue.withAlphaComponent(0.45).cgColor)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.addPath(
      shape.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 10))
    context.clip()
    context.drawLinearGradient(
      gradient, start: CGPoint(x: selected.minX, y: selected.minY),
      end: CGPoint(x: selected.maxX, y: selected.maxY), options: [])
    context.endTransparencyLayer()
    context.restoreGState()
  }

  private func makeCancelButton() -> NSButton {
    let symbol =
      NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel selection")?
      .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) ?? NSImage()
    let button = NSButton(image: symbol, target: self, action: #selector(cancelSelection))
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.backgroundColor = MagicCursorArt.pillBottom.cgColor
    button.layer?.cornerRadius = 18
    button.layer?.borderWidth = 1
    button.layer?.borderColor = MagicCursorArt.glowBlue.withAlphaComponent(0.28).cgColor
    button.layer?.shadowColor = NSColor.black.cgColor
    button.layer?.shadowOpacity = 0.3
    button.layer?.shadowRadius = 8
    button.layer?.shadowOffset = .zero
    button.contentTintColor = MagicCursorArt.textColor
    button.toolTip = "Cancel (Esc)"
    button.setAccessibilityLabel("Cancel selection")
    button.keyEquivalent = "\u{1b}"
    return button
  }
}

/// The floating "Drag to select anything" pill that follows the pointer,
/// styled after Magic Pointer's navy glass prompt bubble with a blue rim.
@MainActor
private final class HintPillView: NSView {
  var message = "" {
    didSet {
      guard message != oldValue else { return }
      needsDisplay = true
    }
  }

  private let height: CGFloat = 46
  private let textAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: MagicCursorArt.textColor,
  ]
  private let keyAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
    .foregroundColor: MagicCursorArt.secondaryTextColor,
  ]

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.35
    layer?.shadowRadius = 12
    layer?.shadowOffset = CGSize(width: 0, height: -3)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { nil }

  var preferredSize: CGSize {
    let text = (message as NSString).size(withAttributes: textAttributes)
    return CGSize(width: ceil(text.width) + 22 + 12 + keySize.width + 14, height: height)
  }

  private var keySize: CGSize {
    let text = ("esc" as NSString).size(withAttributes: keyAttributes)
    return CGSize(width: ceil(text.width) + 12, height: 20)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    let pill = NSBezierPath(
      roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2, yRadius: height / 2)
    NSGradient(starting: MagicCursorArt.pillTop, ending: MagicCursorArt.pillBottom)?
      .draw(in: pill, angle: -90)
    MagicCursorArt.glowBlue.withAlphaComponent(0.28).setStroke()
    pill.lineWidth = 1
    pill.stroke()

    let text = message as NSString
    let textSize = text.size(withAttributes: textAttributes)
    text.draw(
      at: CGPoint(x: 22, y: (bounds.height - textSize.height) / 2),
      withAttributes: textAttributes)

    let key = CGRect(
      x: bounds.maxX - 14 - keySize.width, y: (bounds.height - keySize.height) / 2,
      width: keySize.width, height: keySize.height)
    let keycap = NSBezierPath(roundedRect: key, xRadius: 6, yRadius: 6)
    NSColor.white.withAlphaComponent(0.07).setFill()
    keycap.fill()
    MagicCursorArt.glowBlue.withAlphaComponent(0.4).setStroke()
    keycap.lineWidth = 1
    keycap.stroke()
    let label = "esc" as NSString
    let labelSize = label.size(withAttributes: keyAttributes)
    label.draw(
      at: CGPoint(x: key.midX - labelSize.width / 2, y: key.midY - labelSize.height / 2),
      withAttributes: keyAttributes)
  }
}
