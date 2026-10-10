import AppKit

@main
enum AppMain {
  @MainActor static func main() {
    let app = NSApplication.shared
    let delegate = AppController()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    withExtendedLifetime(delegate) {
      app.run()
    }
  }
}
