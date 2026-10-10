import AppKit

/// Code-drawn artwork for the selection cursor, overlay, menu bar icon, and
/// panel glyph, following the Googlebook Magic Pointer launch visuals.
///
/// Drawing in code keeps every asset crisp at each backing scale without bundled
/// image resources, which Swift Package Manager executables cannot easily ship.
@MainActor
enum MagicCursorArt {
  static let textColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.97, alpha: 1)
  static let secondaryTextColor = NSColor(srgbRed: 0.72, green: 0.76, blue: 0.84, alpha: 1)
  static let glowBlue = NSColor(srgbRed: 0.345, green: 0.533, blue: 0.957, alpha: 1)
  static let pillTop = NSColor(srgbRed: 0.137, green: 0.196, blue: 0.325, alpha: 0.96)
  static let pillBottom = NSColor(srgbRed: 0.090, green: 0.129, blue: 0.227, alpha: 0.96)

  /// Gemini-style spectrum used for glows, halftones, and the thinking edge.
  static let spectrum: [NSColor] = [
    NSColor(srgbRed: 0.278, green: 0.533, blue: 0.976, alpha: 1),
    NSColor(srgbRed: 0.608, green: 0.447, blue: 0.949, alpha: 1),
    NSColor(srgbRed: 0.937, green: 0.408, blue: 0.533, alpha: 1),
    NSColor(srgbRed: 0.976, green: 0.722, blue: 0.290, alpha: 1),
    NSColor(srgbRed: 0.235, green: 0.769, blue: 0.541, alpha: 1),
  ]

  static let pointerCursor = NSCursor(image: pointerImage(size: 40), hotSpot: pointerTip)
  static let crosshairCursor = NSCursor(image: crosshairImage(), hotSpot: crosshairCenter)
  static let statusIcon = makeStatusIcon()
  static let glyph = pointerImage(size: 72)

  // NSCursor hot spots use the image's top-left origin, matching these y-down drawings.
  private static let pointerTip = CGPoint(x: 9, y: 13)
  private static let crosshairCenter = CGPoint(x: 16, y: 22)

  // A rounded arrowhead like the Googlebook pointer, relative to its tip, y-down.
  // Each vertex carries its own corner radius so the tip stays precise.
  private static let arrowVertices: [(point: CGPoint, radius: CGFloat)] = [
    (CGPoint(x: 0, y: 0), 0.9),
    (CGPoint(x: 1.3, y: 18.6), 1.8),
    (CGPoint(x: 6.7, y: 12.9), 1.2),
    (CGPoint(x: 15.6, y: 14.4), 1.8),
  ]

  static func pointerImage(size: CGFloat) -> NSImage {
    render(size: CGSize(width: size, height: size)) { context, scale in
      context.scaleBy(x: size / 40, y: size / 40)
      let unit = scale * size / 40
      let shape = CGMutablePath()
      shape.addPath(roundedPolygon(arrowVertices, offset: pointerTip))
      shape.addPath(
        sparkPath(center: CGPoint(x: pointerTip.x + 16, y: pointerTip.y - 0.6), radius: 6))
      drawGlowingWhite(shape, outline: 1.4, in: context, unit: unit)
    }
  }

  private static func crosshairImage() -> NSImage {
    render(size: CGSize(width: 40, height: 40)) { context, scale in
      let center = crosshairCenter
      let arm: CGFloat = 8
      let cross = CGMutablePath()
      cross.move(to: CGPoint(x: center.x - arm, y: center.y))
      cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
      cross.move(to: CGPoint(x: center.x, y: center.y - arm))
      cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
      let shape = CGMutablePath()
      shape.addPath(
        cross.copy(strokingWithWidth: 2.2, lineCap: .round, lineJoin: .round, miterLimit: 4))
      shape.addPath(sparkPath(center: CGPoint(x: center.x + 11, y: center.y - 10), radius: 5.4))
      drawGlowingWhite(shape, outline: 1.2, in: context, unit: scale)
    }
  }

  private static func makeStatusIcon() -> NSImage {
    let image = render(size: CGSize(width: 18, height: 18)) { context, _ in
      let tip = CGPoint(x: 2.5, y: 4)
      context.saveGState()
      context.translateBy(x: tip.x, y: tip.y)
      context.scaleBy(x: 0.74, y: 0.74)
      context.addPath(roundedPolygon(arrowVertices, offset: .zero))
      context.restoreGState()
      context.addPath(sparkPath(center: CGPoint(x: 13.6, y: 4.4), radius: 3.8))
      context.setFillColor(CGColor(gray: 0, alpha: 1))
      context.fillPath()
    }
    image.isTemplate = true
    image.accessibilityDescription = "Magic Cursor"
    return image
  }

  /// A four-point star whose concave sides curve through points near the
  /// center, matching the Gemini-style spark used by Magic Pointer.
  static func sparkPath(center: CGPoint, radius: CGFloat) -> CGPath {
    let pinch = radius * 0.2
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x, y: center.y - radius))
    path.addQuadCurve(
      to: CGPoint(x: center.x + radius, y: center.y),
      control: CGPoint(x: center.x + pinch, y: center.y - pinch))
    path.addQuadCurve(
      to: CGPoint(x: center.x, y: center.y + radius),
      control: CGPoint(x: center.x + pinch, y: center.y + pinch))
    path.addQuadCurve(
      to: CGPoint(x: center.x - radius, y: center.y),
      control: CGPoint(x: center.x - pinch, y: center.y + pinch))
    path.addQuadCurve(
      to: CGPoint(x: center.x, y: center.y - radius),
      control: CGPoint(x: center.x - pinch, y: center.y - pinch))
    path.closeSubpath()
    return path
  }

  /// Fills a selection with a rainbow halftone, like the dot shimmer Magic
  /// Pointer shows over content. Dots are denser at the edges so the selected
  /// content stays readable in the middle.
  static func drawHalftone(in rect: CGRect, context: CGContext) {
    guard
      let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: spectrum.map(\.cgColor) as CFArray, locations: nil),
      let fade = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [CGColor(gray: 0, alpha: 0.32), CGColor(gray: 0, alpha: 0.95)] as CFArray,
        locations: [0, 1])
    else { return }
    context.saveGState()
    context.clip(to: rect)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor(patternImage: halftoneTile).setFill()
    rect.fill()
    context.setBlendMode(.sourceIn)
    context.drawLinearGradient(
      gradient, start: CGPoint(x: rect.minX, y: rect.minY),
      end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    context.setBlendMode(.destinationIn)
    context.drawRadialGradient(
      fade, startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
      endCenter: CGPoint(x: rect.midX, y: rect.midY),
      endRadius: max(rect.width, rect.height) * 0.62, options: [.drawsAfterEndLocation])
    context.endTransparencyLayer()
    context.restoreGState()
  }

  private static let halftoneTile: NSImage = {
    let tile = NSImage(size: CGSize(width: 9, height: 9), flipped: false) { _ in
      NSColor.white.setFill()
      NSBezierPath(ovalIn: CGRect(x: 3.2, y: 3.2, width: 2.6, height: 2.6)).fill()
      return true
    }
    return tile
  }()

  private static func roundedPolygon(
    _ vertices: [(point: CGPoint, radius: CGFloat)], offset: CGPoint
  ) -> CGPath {
    let points = vertices.map {
      (point: CGPoint(x: $0.point.x + offset.x, y: $0.point.y + offset.y), radius: $0.radius)
    }
    let path = CGMutablePath()
    let first = points[0].point
    let last = points[points.count - 1].point
    path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
    for index in points.indices {
      let next = points[(index + 1) % points.count].point
      path.addArc(tangent1End: points[index].point, tangent2End: next, radius: points[index].radius)
    }
    path.closeSubpath()
    return path
  }

  /// Draws a white shape with a soft multicolor halo, matching the Gemini glow
  /// around the launch-video pointer. A faint navy outline keeps the white
  /// shape visible on white backgrounds, where the halo alone would vanish.
  private static func drawGlowingWhite(
    _ shape: CGPath, outline: CGFloat, in context: CGContext, unit: CGFloat
  ) {
    // Shadow offsets and blur are in device pixels and ignore the CTM, so they
    // are scaled by hand to look the same at every backing scale.
    let halos: [(NSColor, CGSize)] = [
      (spectrum[0], CGSize(width: -2.4, height: 0.8)),
      (spectrum[1], CGSize(width: 0.4, height: 2.4)),
      (spectrum[2], CGSize(width: 2.6, height: -0.6)),
      (spectrum[3], CGSize(width: 1.2, height: -2.4)),
      (spectrum[4], CGSize(width: -1.6, height: -2.2)),
    ]
    for (color, offset) in halos {
      context.saveGState()
      context.setShadow(
        offset: CGSize(width: offset.width * unit, height: offset.height * unit),
        blur: 5 * unit, color: color.withAlphaComponent(0.95).cgColor)
      context.addPath(shape)
      context.setFillColor(color.withAlphaComponent(0.55).cgColor)
      context.fillPath()
      context.restoreGState()
    }
    context.addPath(shape)
    context.setLineWidth(outline)
    context.setLineJoin(.round)
    context.setStrokeColor(CGColor(srgbRed: 0.06, green: 0.09, blue: 0.2, alpha: 0.42))
    context.strokePath()
    guard
      let fill = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
          CGColor(gray: 1, alpha: 1), CGColor(srgbRed: 0.88, green: 0.92, blue: 1, alpha: 1),
        ] as CFArray, locations: [0, 1])
    else { return }
    let bounds = shape.boundingBoxOfPath
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawLinearGradient(
      fill, start: CGPoint(x: bounds.minX, y: bounds.minY),
      end: CGPoint(x: bounds.maxX, y: bounds.maxY), options: [])
    context.restoreGState()
  }

  /// Renders explicit 1x, 2x, and 3x bitmaps. NSCursor picks the matching
  /// representation; a single lazily drawn image can be rasterized at 1x.
  private static func render(size: CGSize, draw: (CGContext, CGFloat) -> Void) -> NSImage {
    let image = NSImage(size: size)
    for scale in [1, 2, 3] as [CGFloat] {
      guard
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
          pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
          bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: rep)
      else { continue }
      rep.size = size
      let context = graphics.cgContext
      context.translateBy(x: 0, y: size.height * scale)
      context.scaleBy(x: scale, y: -scale)
      draw(context, scale)
      graphics.flushGraphics()
      image.addRepresentation(rep)
    }
    return image
  }
}
