import AppKit
import Combine
import MagicCursorCore
import SwiftUI

/// A borderless, transparent panel that hosts the floating card. Borderless
/// windows cannot become key by default, which would block typing follow-ups.
@MainActor
final class FloatingPanel: NSPanel {
  var onCancel: () -> Void = {}
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { onCancel() }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
  private let model = AppModel()
  private var statusItem: NSStatusItem?
  private var panel: FloatingPanel?
  private var overlayWindow: SelectionWindow?
  private var detector = ShakeDetector()
  private var mouseTimer: Timer?
  private var pauseItem: NSMenuItem?
  private var menuTracking = false
  private var previousApplication: NSRunningApplication?
  private var restorePanelOnCancel = false
  private var panelHeightObserver: AnyCancellable?
  private var panelWidthObserver: AnyCancellable?
  private var settingsWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    model.selectRegion = { [weak self] in self?.beginSelection() }
    model.addRegion = { [weak self] in self?.beginSelection(appending: true) }
    model.closePanel = { [weak self] in self?.hidePanel() }
    model.openSettings = { [weak self] in self?.showSettings() }
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(makeMenuItem("Open assistant panel", action: #selector(openPanel)))
    appMenu.addItem(makeMenuItem("Settings…", action: #selector(openSettingsWindow), key: ","))
    appMenu.addItem(.separator())
    appMenu.addItem(makeMenuItem("Quit Magic Cursor", action: #selector(quit), key: "q"))
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)
    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)
    NSApplication.shared.mainMenu = mainMenu
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = MagicCursorArt.statusIcon
    item.button?.toolTip = "Magic Cursor - shake, select, understand"
    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(withTitle: "Magic Cursor", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(makeMenuItem("Select a screen region...", action: #selector(captureNow)))
    menu.addItem(makeMenuItem("Open assistant panel", action: #selector(openPanel)))
    let pause = makeMenuItem("Enable shake to select", action: #selector(toggleShake))
    menu.addItem(pause)
    pauseItem = pause
    menu.addItem(.separator())
    menu.addItem(makeMenuItem("Settings…", action: #selector(openSettingsWindow), key: ","))
    menu.addItem(.separator())
    menu.addItem(makeMenuItem("Quit Magic Cursor", action: #selector(quit), key: "q"))
    item.menu = menu
    statusItem = item
    mouseTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.observeMouse() }
    }
    showPanel()
  }

  private func makeMenuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    return item
  }

  func menuWillOpen(_ menu: NSMenu) {
    menuTracking = true
    pauseItem?.state = model.shakeEnabled ? .on : .off
    detector.reset()
  }

  func menuDidClose(_ menu: NSMenu) {
    menuTracking = false
    detector.reset()
  }

  @objc private func captureNow() { beginSelection() }
  @objc private func openPanel() { showPanel() }
  @objc private func openSettingsWindow() { showSettings() }
  @objc private func toggleShake() {
    model.shakeEnabled.toggle()
    detector.reset()
  }
  @objc private func quit() { NSApplication.shared.terminate(nil) }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showPanel()
    return false
  }

  private func observeMouse() {
    guard model.shakeEnabled, !model.phase.isBusy, overlayWindow == nil,
      NSEvent.pressedMouseButtons == 0, !menuTracking
    else {
      detector.reset()
      return
    }
    detector.sensitivity = model.sensitivity
    if detector.add(NSEvent.mouseLocation, at: ProcessInfo.processInfo.systemUptime) {
      beginSelection()
    }
  }

  private func screenUnderPointer() -> NSScreen? {
    NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
  }

  /// Opens the selection overlay. When `appending`, the new region is added
  /// to the current chat instead of starting a new one.
  private func beginSelection(appending: Bool = false) {
    guard overlayWindow == nil else { return }
    model.refreshAvailability()
    guard model.screenPermission else {
      model.errorMessage =
        "Screen Recording permission is needed to capture your selection. Click Allow screen capture below."
      showPanel(placement: .keep)
      return
    }
    guard let screen = screenUnderPointer() else {
      model.errorMessage = "No display is available."
      showPanel(placement: .keep)
      return
    }
    let appending = appending && model.canAddSelection
    if !appending { model.beginSelection() }
    restorePanelOnCancel = panel?.isVisible == true
    panel?.orderOut(nil)
    detector.reset()
    let window = SelectionWindow(
      contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = false
    window.level = .screenSaver
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.acceptsMouseMovedEvents = true
    window.ignoresMouseEvents = false
    let view = SelectionOverlay(frame: CGRect(origin: .zero, size: screen.frame.size))
    if appending { view.idleMessage = "Drag to add another selection" }
    view.onCancel = { [weak self] in
      guard let self else { return }
      self.dismissOverlay()
      if !appending { self.model.cancelSelection() }
      if self.restorePanelOnCancel { self.showPanel(placement: .keep) }
    }
    view.onSelection = { [weak self] rectangle in
      guard let self else { return }
      let displayID =
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint32Value
      self.dismissOverlay()
      guard let displayID else {
        self.model.cancelSelection()
        self.model.errorMessage = "Could not identify the selected display."
        self.showPanel(placement: .keep)
        return
      }
      let captureRectangle = SelectionGeometry.captureRectangle(
        rectangle, displayHeight: screen.frame.height)
      if appending {
        self.model.addSelection(
          displayID: displayID, rectangle: captureRectangle, scale: screen.backingScaleFactor)
        // Keep the card where it is so adding a region does not make it jump.
        self.showPanel(placement: .keep)
      } else {
        self.model.process(
          displayID: displayID, rectangle: captureRectangle, scale: screen.backingScaleFactor)
        let global = rectangle.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        self.showPanel(placement: .beside(global, screen))
      }
    }
    window.title = "Select a screen region"
    window.contentView = view
    overlayWindow = window
    previousApplication = NSWorkspace.shared.frontmostApplication
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.alphaValue = 0
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.14
      window.animator().alphaValue = 1
    }
  }

  private func dismissOverlay() {
    (overlayWindow?.contentView as? SelectionOverlay)?.restoreCursor()
    overlayWindow?.orderOut(nil)
    overlayWindow?.contentView = nil
    overlayWindow = nil
    if let previousApplication,
      previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier
    {
      // Selection temporarily activates an accessory app to receive Escape.
      // Return focus to the source app instead of leaving it without a key window.
      previousApplication.activate(options: [])
    }
    previousApplication = nil
    detector.reset()
  }

  enum PanelPlacementRequest {
    /// Open next to a just-selected region (global AppKit coordinates).
    case beside(CGRect, NSScreen)
    /// Keep the card where it was; place at the top right if never shown.
    case keep
    /// Top right of the display under the pointer.
    case topRight
  }

  private func showPanel(placement: PanelPlacementRequest = .keep) {
    guard overlayWindow == nil else { return }
    model.refreshAvailability()
    let created = panel == nil
    if panel == nil {
      let panel = FloatingPanel(
        contentRect: CGRect(
          x: 0, y: 0, width: PanelLayout.windowWidth(for: model.cardWidth), height: 600),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false
      )
      panel.title = "Magic Cursor"
      // The window is sized to the card and pills (see fitPanelHeight). Its
      // margins are transparent, and the card draws its own glow and shadow.
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.isMovableByWindowBackground = true
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.level = .floating
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.appearance = NSAppearance(named: .darkAqua)
      panel.onCancel = { [weak self] in self?.hidePanel() }
      let hosting = NSHostingView(rootView: AssistantPanel(model: model))
      // The controller sizes the panel from measured content; stop the
      // hosting view from also imposing SwiftUI's ideal size on the window.
      hosting.sizingOptions = []
      panel.contentView = hosting
      panel.delegate = self
      self.panel = panel
      panelHeightObserver = model.$panelContentHeight
        .removeDuplicates()
        .sink { [weak self] height in
          // @Published emits before the property changes; apply after it lands.
          DispatchQueue.main.async { self?.fitPanelHeight(height) }
        }
      panelWidthObserver = model.$cardWidth
        .removeDuplicates()
        .sink { [weak self] width in
          DispatchQueue.main.async { self?.fitPanelWidth(width) }
        }
    }
    guard let panel else { return }
    let height = max(120, model.panelContentHeight)
    let windowWidth = PanelLayout.windowWidth(for: model.cardWidth)
    var request = placement
    if case .keep = request, created { request = .topRight }
    switch request {
    case .beside(let selection, let screen):
      let visible = screen.visibleFrame
      updateMaximumHeight(for: visible)
      let topLeft = PanelPlacement.topLeft(
        beside: selection, in: visible,
        metrics: .init(
          cardWidth: model.cardWidth, sideMargin: PanelLayout.shadowMargin,
          topMargin: PanelLayout.topMargin))
      let frame = CGRect(x: topLeft.x, y: topLeft.y - height, width: windowWidth, height: height)
      panel.setFrame(PanelPlacement.clampedFrame(frame, in: visible), display: true)
    case .topRight:
      guard let screen = screenUnderPointer() else { break }
      let visible = screen.visibleFrame
      updateMaximumHeight(for: visible)
      let frame = CGRect(
        x: visible.maxX - windowWidth, y: visible.maxY - height,
        width: windowWidth, height: height)
      panel.setFrame(PanelPlacement.clampedFrame(frame, in: visible), display: true)
    case .keep:
      if let visible = panel.screen?.visibleFrame { updateMaximumHeight(for: visible) }
    }
    panel.makeKeyAndOrderFront(nil)
  }

  private func updateMaximumHeight(for visible: CGRect) {
    model.panelMaxHeight = visible.height - PanelLayout.topMargin - PanelLayout.bottomMargin - 10
  }

  /// Applies a width change from the Settings window. Edge drags already set
  /// the frame themselves, so this is a no-op for them. The left edge stays
  /// put unless the wider card would run off the display.
  private func fitPanelWidth(_ cardWidth: CGFloat) {
    guard let panel else { return }
    let target = PanelLayout.windowWidth(for: cardWidth)
    guard abs(panel.frame.width - target) >= 0.5 else { return }
    var frame = panel.frame
    frame.size.width = target
    if let visible = (panel.screen ?? screenUnderPointer())?.visibleFrame {
      let overflow = frame.maxX - (visible.maxX + PanelLayout.shadowMargin)
      if overflow > 0 { frame.origin.x -= overflow }
    }
    panel.setFrame(frame, display: true)
  }

  private func showSettings() {
    model.refreshAvailability()
    if settingsWindow == nil {
      let controller = NSHostingController(rootView: PreferencesView(model: model))
      let window = NSWindow(contentViewController: controller)
      window.title = "Magic Cursor Settings"
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      // Match the floating card's level so Settings never opens behind it.
      window.level = .floating
      window.center()
      settingsWindow = window
    }
    // Accessory apps are not frontmost by default; activate so the window
    // takes keyboard focus instead of appearing behind the current app.
    NSApplication.shared.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  /// Resizes the panel to its content while keeping the top edge fixed, so
  /// the card grows downward as the conversation streams in. If it would run
  /// off the bottom of the display, it moves up instead.
  private func fitPanelHeight(_ height: CGFloat) {
    guard let panel, height > 0 else { return }
    let target = ceil(height)
    guard abs(panel.frame.height - target) >= 0.5 else { return }
    var frame = panel.frame
    frame.origin.y = frame.maxY - target
    frame.size.height = target
    if let visible = (panel.screen ?? screenUnderPointer())?.visibleFrame {
      frame = PanelPlacement.clampedFrame(frame, in: visible)
    }
    panel.setFrame(frame, display: true)
  }

  private func hidePanel() {
    model.stop()
    model.stopSpeaking()
    panel?.orderOut(nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hidePanel()
    return false
  }

  func applicationDidChangeScreenParameters(_ notification: Notification) {
    if overlayWindow != nil {
      dismissOverlay()
      model.cancelSelection()
    }
    if panel?.isVisible == true { showPanel(placement: .topRight) }
  }

  func applicationWillTerminate(_ notification: Notification) {
    mouseTimer?.invalidate()
    dismissOverlay()
    model.stop()
  }
}
