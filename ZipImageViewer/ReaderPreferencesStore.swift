import Foundation

final class ReaderPreferencesStore: NSObject {
    static let didChangeNotification = Notification.Name("ReaderPreferencesStore.didChange")
    static let storageKey = "readerPreferences.v1"
    private let defaults: UserDefaults
    private(set) var preferences: ReaderPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(ReaderPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = ReaderPreferences()
        }
        super.init()
    }

    /// Call on the UI thread when binding to a reader; observers receive changes synchronously.
    func update(_ preferences: ReaderPreferences) {
        let validated = preferences.validated()
        guard validated != self.preferences,
              let data = try? JSONEncoder().encode(validated) else { return }
        self.preferences = validated
        defaults.set(data, forKey: Self.storageKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
