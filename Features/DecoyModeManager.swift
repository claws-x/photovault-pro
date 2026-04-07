import Foundation

// This file intentionally keeps only review-safe vault preferences.
// The app no longer ships any disguised or hidden-entry behavior.

struct VaultPrivacyPreferences: Codable, Equatable {
    var autoLockOnBackground = true
    var allowsBiometricUnlock = true
    var showsImportEducation = true
}

@MainActor
final class VaultPrivacyPreferencesStore: ObservableObject {
    static let shared = VaultPrivacyPreferencesStore()

    @Published private(set) var preferences = VaultPrivacyPreferences()

    private let defaultsKey = "vault_privacy_preferences"

    private init() {
        load()
    }

    func update(_ updateBlock: (inout VaultPrivacyPreferences) -> Void) {
        var updated = preferences
        updateBlock(&updated)
        preferences = updated
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(VaultPrivacyPreferences.self, from: data) else {
            return
        }

        preferences = decoded
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(preferences) else {
            return
        }

        UserDefaults.standard.set(encoded, forKey: defaultsKey)
    }
}
