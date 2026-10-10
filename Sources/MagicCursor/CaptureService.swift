import AppKit
import MagicCursorCore
import ScreenCaptureKit
import Vision

enum CaptureService {
  enum CaptureError: LocalizedError {
    case missingDisplay, permissionDenied
    var errorDescription: String? {
      switch self {
      case .missingDisplay: "The selected display disconnected. Select a region again."
      case .permissionDenied:
        "Allow Magic Cursor in System Settings > Privacy & Security > Screen & System Audio Recording, then try again. If it is missing, click + and select Magic Cursor.app. You may need to quit and reopen the app."
      }
    }
  }

  static func capture(displayID: CGDirectDisplayID, rectangle: CGRect, scale: CGFloat) async throws
    -> CGImage
  {
    guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    try Task.checkCancellation()
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw CaptureError.missingDisplay
    }
    let ownApp = content.applications.filter {
      $0.processID == ProcessInfo.processInfo.processIdentifier
    }
    let filter = SCContentFilter(
      display: display, excludingApplications: ownApp, exceptingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = rectangle
    let size = SelectionGeometry.pixelSize(for: rectangle, scale: scale)
    configuration.width = Int(size.width)
    configuration.height = Int(size.height)
    configuration.showsCursor = false
    configuration.captureResolution = .best
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
    try Task.checkCancellation()
    return image
  }

  static func recognizeText(in image: CGImage) async throws -> String {
    // Vision recognition is CPU work; keep it off the UI actor. Only this
    // explicitly selected crop is processed, and no capture is saved to disk.
    let text = try await Task.detached(priority: .userInitiated) {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.automaticallyDetectsLanguage = true
      try VNImageRequestHandler(cgImage: image).perform([request])
      return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
        separator: "\n")
    }.value
    try Task.checkCancellation()
    return text
  }
}
