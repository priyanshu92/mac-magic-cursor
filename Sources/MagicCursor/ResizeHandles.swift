import AppKit
import SwiftUI

/// Invisible handles along the card's sides, bottom edge, and bottom corners.
/// They behave like macOS window edges: the cursor changes on hover, dragging
/// resizes, and double-clicking a corner restores the default size.
///
/// Each handle straddles the card edge, extending well into the window's
/// transparent margin where nothing else is clickable. Only a few points
/// reach inside the card, so the scroll bar, Ask field, and buttons near the
/// edges keep working. All offsets keep the handles within the window margins
/// (26 pt at the sides, 36 pt below), or they would be clipped.
struct ResizeHandles: View {
  let model: AppModel
  /// The prompt and welcome cards hug their content, so only width applies.
  let allowsHeight: Bool

  /// Points each handle extends outside and inside the card edge.
  private let sideOutside: CGFloat = 14
  private let leftInside: CGFloat = 6
  // Smaller on the right so the overlay scroll bar stays easy to grab.
  private let rightInside: CGFloat = 4
  private let bottomOutside: CGFloat = 12
  private let bottomInside: CGFloat = 6
  private let cornerOutside: CGFloat = 18
  private let cornerInside: CGFloat = 16

  var body: some View {
    Color.clear
      .overlay(alignment: .leading) {
        handle([.left])
          .frame(width: sideOutside + leftInside)
          .padding(.vertical, 22)
          .offset(x: -sideOutside)
      }
      .overlay(alignment: .trailing) {
        handle([.right])
          .frame(width: sideOutside + rightInside)
          .padding(.vertical, 22)
          .offset(x: sideOutside)
      }
      .overlay(alignment: .bottom) {
        if allowsHeight {
          handle([.bottom])
            .frame(height: bottomOutside + bottomInside)
            .padding(.horizontal, cornerInside)
            .offset(y: bottomOutside)
        }
      }
      .overlay(alignment: .bottomLeading) {
        if allowsHeight {
          handle([.left, .bottom])
            .frame(width: cornerOutside + cornerInside, height: cornerOutside + cornerInside)
            .offset(x: -cornerOutside, y: cornerOutside)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if allowsHeight {
          handle([.right, .bottom])
            .frame(width: cornerOutside + cornerInside, height: cornerOutside + cornerInside)
            .offset(x: cornerOutside, y: cornerOutside)
        }
      }
  }

  private func handle(_ edges: ResizeEdges) -> some View {
    ResizeHandle(edges: edges, model: model)
      .accessibilityHidden(true)
  }
}

struct ResizeEdges: OptionSet, Sendable {
  let rawValue: Int
  static let left = ResizeEdges(rawValue: 1 << 0)
  static let right = ResizeEdges(rawValue: 1 << 1)
  static let bottom = ResizeEdges(rawValue: 1 << 2)
}

private struct ResizeHandle: NSViewRepresentable {
  let edges: ResizeEdges
  let model: AppModel

  func makeNSView(context: Context) -> ResizeHandleView {
    let view = ResizeHandleView()
    view.edges = edges
    view.model = model
    return view
  }

  func updateNSView(_ view: ResizeHandleView, context: Context) {
    view.edges = edges
    view.model = model
  }
}

@MainActor
private final class ResizeHandleView: NSView {
  var edges: ResizeEdges = []
  weak var model: AppModel?
  private var tracking: NSTrackingArea?
  private var start: (mouse: CGPoint, frame: CGRect, width: CGFloat, height: CGFloat)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // The window server lets clicks fall through fully transparent pixels of
    // a non-opaque window. Without this faint fill, the part of each handle
    // outside the card would never receive the mouse, leaving only a sliver
    // inside the card edge to grab.
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.02).cgColor
  }

  required init?(coder: NSCoder) { nil }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  private var cursor: NSCursor {
    if #available(macOS 15, *) {
      switch edges {
      case [.left], [.right]:
        return .frameResize(position: edges == [.left] ? .left : .right, directions: .all)
      case [.bottom]: return .frameResize(position: .bottom, directions: .all)
      case [.left, .bottom]: return .frameResize(position: .bottomLeft, directions: .all)
      default: return .frameResize(position: .bottomRight, directions: .all)
      }
    }
    return edges == [.bottom] ? .resizeUpDown : .resizeLeftRight
  }

  // The panel is non-activating and often not key, where cursor rects are
  // ignored. An always-active tracking area still delivers cursor updates.
  override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    tracking = area
    super.updateTrackingAreas()
  }

  override func cursorUpdate(with event: NSEvent) { cursor.set() }
  override func mouseEntered(with event: NSEvent) { cursor.set() }
  override func mouseExited(with event: NSEvent) {
    if start == nil { NSCursor.arrow.set() }
  }

  override func mouseDown(with event: NSEvent) {
    guard let model, let window else { return }
    if event.clickCount == 2 {
      model.resetCardSize()
      return
    }
    start = (NSEvent.mouseLocation, window.frame, model.cardWidth, model.measuredCardHeight)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start, let model, let window else { return }
    // Screen coordinates stay stable while the window moves under the handle.
    let mouse = NSEvent.mouseLocation
    let dx = mouse.x - start.mouse.x
    let dy = mouse.y - start.mouse.y
    cursor.set()

    let margins = start.frame.width - start.width
    var width = start.width
    if edges.contains(.right) { width = start.width + dx }
    if edges.contains(.left) { width = start.width - dx }
    width = AppModel.clampWidth(width)
    if let visible = window.screen?.visibleFrame {
      width = min(width, visible.width - margins)
    }
    var frame = window.frame
    frame.size.width = width + margins
    // Dragging the left edge keeps the right edge fixed, like a window.
    frame.origin.x = edges.contains(.left) ? start.frame.maxX - frame.width : start.frame.minX
    window.setFrame(frame, display: true)
    model.cardWidth = width

    if edges.contains(.bottom) {
      // AppKit's y axis points up, so dragging down (negative dy) grows the card.
      let height = start.height - dy
      model.userCardHeight = min(max(height, AppModel.minimumCardHeight), model.panelMaxHeight)
    }
  }

  override func mouseUp(with event: NSEvent) {
    start = nil
    if !bounds.contains(convert(event.locationInWindow, from: nil)) { NSCursor.arrow.set() }
  }
}
