import Foundation

#if canImport(CoreGraphics)
  import CoreGraphics
#endif

public enum SelectionGeometry {
  public static func rectangle(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect? {
    guard
      [
        start.x, start.y, end.x, end.y, bounds.minX, bounds.minY,
        bounds.width, bounds.height,
      ].allSatisfy(\.isFinite),
      bounds.width > 0, bounds.height > 0
    else { return nil }
    let rectangle = CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y),
      width: abs(end.x - start.x), height: abs(end.y - start.y)
    ).intersection(bounds)
    guard !rectangle.isNull, rectangle.width >= 8, rectangle.height >= 8 else { return nil }
    return rectangle
  }

  public static func captureRectangle(_ localRectangle: CGRect, displayHeight: CGFloat) -> CGRect {
    // AppKit uses a bottom-left origin; ScreenCaptureKit sourceRect uses
    // display-local top-left points, not global coordinates or Retina pixels.
    // https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect
    CGRect(
      x: localRectangle.minX, y: displayHeight - localRectangle.maxY,
      width: localRectangle.width, height: localRectangle.height
    )
  }

  public static func pixelSize(for rectangle: CGRect, scale: CGFloat, limit: CGFloat = 4096)
    -> CGSize
  {
    let width = rectangle.width * scale
    let height = rectangle.height * scale
    let factor = min(1, limit / max(width, height))
    return CGSize(
      width: max(1, (width * factor).rounded()), height: max(1, (height * factor).rounded()))
  }
}
