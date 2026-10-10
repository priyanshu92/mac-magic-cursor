import Foundation
import MagicCursorCore

#if canImport(CoreGraphics)
  import CoreGraphics
#endif

// Command Line Tools do not ship XCTest or Swift Testing. This executable keeps
// core regression checks runnable with the same compiler used to build the app.
@main
enum Checks {
  static func main() {
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
    func shake(
      _ values: [CGFloat], vertical: Bool = false, interval: TimeInterval = 0.08,
      sensitivity: ShakeDetector.Sensitivity = .standard
    ) -> [Bool] {
      var detector = ShakeDetector(sensitivity: sensitivity)
      return values.enumerated().map { index, value in
        detector.add(
          CGPoint(x: vertical ? 100 : value, y: vertical ? value : 100),
          at: Double(index) * interval
        )
      }
    }

    check(
      "Short four-stroke movements do not activate",
      !shake([0, 85, 0, 85, 0]).contains(true))
    check(
      "Horizontal shake activates only on sixth stroke",
      shake([0, 85, 0, 85, 0, 85, 0]) == [false, false, false, false, false, false, true])
    check("Vertical shake activates", shake([0, 85, 0, 85, 0, 85, 0], vertical: true).last == true)
    check(
      "Repeated short mouse movements do not activate",
      !shake([0, 40, 0, 40, 0, 40, 0, 40]).contains(true))
    check(
      "Wide swipes with too few reversals do not activate",
      !shake([0, 500, 0, 500, 0]).contains(true))
    check(
      "Many small wiggles cannot satisfy the minimum span",
      !shake((0..<16).map { $0.isMultiple(of: 2) ? 0 : 40 }, interval: 0.04).contains(true))
    check(
      "Steady movement does not activate", !shake((0..<30).map { CGFloat($0 * 30) }).contains(true))
    check("Tiny jitter does not activate", !shake([0, 4, -3, 6, 0, 8, 0, 5, 0]).contains(true))
    check("Single reversal does not activate", !shake([0, 100, 200, 100, 0]).contains(true))
    check(
      "Slow shakes do not activate",
      !shake([0, 85, 0, 85, 0, 85, 0], interval: 0.2).contains(true))
    check(
      "Gentle sensitivity activates at lower travel",
      shake([0, 60, 0, 60, 0, 60], sensitivity: .gentle).last == true)
    check(
      "Deliberate sensitivity rejects lower travel",
      !shake([0, 70, 0, 70, 0, 70, 0], sensitivity: .deliberate).contains(true))
    check(
      "Deliberate sensitivity accepts a pronounced seven-stroke shake",
      shake([0, 90, 0, 90, 0, 90, 0, 90], sensitivity: .deliberate).last == true)
    check(
      "Small reversals on a steady path are ignored",
      !shake([0, 25, 23, 50, 48, 80, 78, 110, 108, 150]).contains(true))

    var detector = ShakeDetector()
    var activationCount = 0
    for index in 0..<20 {
      if detector.add(CGPoint(x: index.isMultiple(of: 2) ? 0 : 100, y: 0), at: Double(index) * 0.04)
      {
        activationCount += 1
      }
    }
    check("Cooldown prevents repeated activation", activationCount == 1)
    let tooSoon = (0..<8).map { index in
      detector.add(
        CGPoint(x: index.isMultiple(of: 2) ? 0 : 100, y: 0), at: 2.1 + Double(index) * 0.08)
    }
    check("Cooldown remains active for three seconds", !tooSoon.contains(true))
    let afterCooldown = (0..<7).map { index in
      detector.add(
        CGPoint(x: index.isMultiple(of: 2) ? 0 : 100, y: 0), at: 4 + Double(index) * 0.08)
    }
    check("Detector rearms after cooldown", afterCooldown.contains(true))

    detector = ShakeDetector()
    for (index, x) in [0, 100, 0, 100, 0, 100].enumerated() {
      _ = detector.add(CGPoint(x: x, y: 0), at: Double(index) * 0.08)
    }
    detector.reset()
    check("Reset discards partial shake", !detector.add(.zero, at: 0.48))
    check("Invalid point rejected", !detector.add(CGPoint(x: CGFloat.nan, y: 0), at: 1))
    check("Invalid time rejected", !detector.add(.zero, at: .infinity))

    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    for (index, pair) in [
      (CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250)),
      (CGPoint(x: 300, y: 250), CGPoint(x: 100, y: 100)),
      (CGPoint(x: 100, y: 250), CGPoint(x: 300, y: 100)),
      (CGPoint(x: 300, y: 100), CGPoint(x: 100, y: 250)),
    ].enumerated() {
      check(
        "Drag direction \(index) produces expected rectangle",
        SelectionGeometry.rectangle(from: pair.0, to: pair.1, in: bounds)
          == CGRect(x: 100, y: 100, width: 200, height: 150))
    }
    check(
      "Selection clamps to display",
      SelectionGeometry.rectangle(
        from: CGPoint(x: -20, y: -30), to: CGPoint(x: 1200, y: 900), in: bounds) == bounds)
    check("Click rejected", SelectionGeometry.rectangle(from: .zero, to: .zero, in: bounds) == nil)
    check(
      "Narrow selection rejected",
      SelectionGeometry.rectangle(from: .zero, to: CGPoint(x: 7, y: 80), in: bounds) == nil)
    check(
      "Off-screen selection rejected",
      SelectionGeometry.rectangle(
        from: CGPoint(x: 1100, y: 100), to: CGPoint(x: 1200, y: 200), in: bounds) == nil)
    check(
      "Minimum size accepted",
      SelectionGeometry.rectangle(from: .zero, to: CGPoint(x: 8, y: 8), in: bounds)?.size
        == CGSize(width: 8, height: 8))
    check(
      "Capture coordinates flip Y",
      SelectionGeometry.captureRectangle(
        CGRect(x: 100, y: 200, width: 300, height: 150), displayHeight: 800)
        == CGRect(x: 100, y: 450, width: 300, height: 150))
    check(
      "Full screen has zero capture origin",
      SelectionGeometry.captureRectangle(bounds, displayHeight: 800) == bounds)
    check(
      "Retina sizing doubles pixels",
      SelectionGeometry.pixelSize(for: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2)
        == CGSize(width: 400, height: 200))
    check(
      "Oversized capture preserves aspect ratio",
      SelectionGeometry.pixelSize(for: CGRect(x: 0, y: 0, width: 4000, height: 2000), scale: 2)
        == CGSize(width: 4096, height: 2048))
    check(
      "Invalid rectangle rejected",
      SelectionGeometry.rectangle(
        from: CGPoint(x: CGFloat.nan, y: 0), to: CGPoint(x: 100, y: 100), in: bounds) == nil)

    let insights = SelectionInsights.parse(
      """
      Here are some ideas:
      Title: "Supplier portal PR."
      - Summarize the key changes
      2. "What does this PR fix?"
      • Draft a review comment.
      - Summarize the key changes
      - Fourth suggestion is dropped
      """)
    check("Insight title is parsed and cleaned", insights.title == "Supplier portal PR")
    check(
      "Insight suggestions accept list marker variants and drop duplicates",
      insights.suggestions == [
        "Summarize the key changes", "What does this PR fix?", "Draft a review comment",
      ])
    check(
      "Preamble without a title marker is not a title",
      SelectionInsights.parse("Sure!\n- Explain this chart").title == nil)
    check(
      "Overlong and trivial suggestions are rejected",
      SelectionInsights.parse("- ok\n- \(String(repeating: "x", count: 61))\n- Explain it")
        .suggestions == ["Explain it"])
    check("Empty insight response is empty", SelectionInsights.parse("") == SelectionInsights())
    check(
      "Bare numbers are not list markers",
      SelectionInsights.parse("2026 was a good year").suggestions.isEmpty)

    let visible = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    let metrics = PanelPlacement.Metrics(cardWidth: 384, sideMargin: 22, topMargin: 8)
    let rightOrigin = PanelPlacement.topLeft(
      beside: CGRect(x: 200, y: 600, width: 400, height: 200), in: visible, metrics: metrics)
    check("Card opens to the right of a selection", rightOrigin == CGPoint(x: 592, y: 808))
    let leftOrigin = PanelPlacement.topLeft(
      beside: CGRect(x: 1200, y: 600, width: 450, height: 200), in: visible, metrics: metrics)
    check(
      "Card opens to the left when the right side lacks room",
      leftOrigin.x + 22 + 384 == 1200 - 14 && leftOrigin.y == 808)
    let belowOrigin = PanelPlacement.topLeft(
      beside: CGRect(x: 100, y: 500, width: 1500, height: 300), in: visible, metrics: metrics)
    check(
      "Card opens below a wide selection and stays on screen",
      belowOrigin.y == 500 - 14 + 8 && belowOrigin.x + 22 >= 8
        && belowOrigin.x + 22 + 384 <= 1728 - 8)
    let topOrigin = PanelPlacement.topLeft(
      beside: CGRect(x: 100, y: 900, width: 200, height: 180), in: visible, metrics: metrics)
    check("Card top never exceeds the visible frame", topOrigin.y == 1080)
    check(
      "Grown frame moves up to stay visible",
      PanelPlacement.clampedFrame(CGRect(x: 0, y: -100, width: 428, height: 500), in: visible)
        == CGRect(x: 0, y: 0, width: 428, height: 500))
    check(
      "Oversized frame is limited to the visible height",
      PanelPlacement.clampedFrame(CGRect(x: 0, y: -100, width: 428, height: 2000), in: visible)
        == CGRect(x: 0, y: 0, width: 428, height: 1080))

    print("\(passed) checks passed; \(failed) failed.")
    if failed > 0 { exit(1) }
  }
}
