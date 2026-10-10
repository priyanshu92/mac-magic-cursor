import Foundation

#if canImport(CoreGraphics)
  import CoreGraphics
#endif

/// Places the floating card beside a selection, like Magic Pointer's card
/// that opens next to what the user pointed at.
///
/// All rectangles use AppKit's bottom-left-origin global coordinates. The
/// window includes transparent margins around the card for its shadow, so the
/// card itself, not the window, is what keeps `gap` from the selection.
public enum PanelPlacement {
  public struct Metrics: Sendable {
    public var cardWidth: CGFloat
    public var sideMargin: CGFloat
    public var topMargin: CGFloat
    public var gap: CGFloat
    public var screenInset: CGFloat

    public init(
      cardWidth: CGFloat, sideMargin: CGFloat, topMargin: CGFloat, gap: CGFloat = 14,
      screenInset: CGFloat = 8
    ) {
      self.cardWidth = cardWidth
      self.sideMargin = sideMargin
      self.topMargin = topMargin
      self.gap = gap
      self.screenInset = screenInset
    }

    var windowWidth: CGFloat { cardWidth + sideMargin * 2 }
  }

  /// Returns the window's top-left point. The caller sizes the height from
  /// content and uses `clampedFrame` to keep the grown window on screen.
  public static func topLeft(
    beside selection: CGRect, in visible: CGRect, metrics: Metrics
  ) -> CGPoint {
    let width = metrics.windowWidth
    let rightX = selection.maxX + metrics.gap - metrics.sideMargin
    let leftX = selection.minX - metrics.gap - metrics.cardWidth - metrics.sideMargin
    let x: CGFloat
    var top = selection.maxY + metrics.topMargin
    if rightX + width <= visible.maxX + metrics.sideMargin - metrics.screenInset {
      x = rightX
    } else if leftX >= visible.minX - metrics.sideMargin + metrics.screenInset {
      x = leftX
    } else {
      // No room on either side: center on the selection and open below it.
      x = selection.midX - width / 2
      top = selection.minY - metrics.gap + metrics.topMargin
    }
    let clampedX = min(
      max(x, visible.minX - metrics.sideMargin + metrics.screenInset),
      visible.maxX + metrics.sideMargin - metrics.screenInset - width)
    return CGPoint(x: clampedX, y: min(top, visible.maxY))
  }

  /// Keeps a window frame inside the visible area, preferring to move it up
  /// when content grows past the bottom edge.
  public static func clampedFrame(_ frame: CGRect, in visible: CGRect) -> CGRect {
    var result = frame
    result.size.height = min(result.height, visible.height)
    if result.minY < visible.minY { result.origin.y = visible.minY }
    if result.maxY > visible.maxY { result.origin.y = visible.maxY - result.height }
    return result
  }
}
