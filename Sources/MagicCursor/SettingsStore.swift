import Foundation

/// The few preference operations the app needs. The app stores settings in
/// `UserDefaults`; checks use `MemorySettingsStore` so they never write plist
/// files into the user's Preferences folder, which cfprefsd may flush after
/// the test process exits.
protocol SettingsStore: AnyObject {
  func setting(forKey key: String) -> Any?
  func setSetting(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsStore {
  func setting(forKey key: String) -> Any? { object(forKey: key) }

  func setSetting(_ value: Any?, forKey key: String) {
    if let value { set(value, forKey: key) } else { removeObject(forKey: key) }
  }
}

final class MemorySettingsStore: SettingsStore {
  private var values: [String: Any] = [:]

  func setting(forKey key: String) -> Any? { values[key] }
  func setSetting(_ value: Any?, forKey key: String) { values[key] = value }
}
