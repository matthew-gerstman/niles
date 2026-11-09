import Foundation
import Security

@testable import NilesCore

// Shared Keychain test support. Keychain tests must not see (or evict) each
// other's items across runs on one simulator, so every test scopes its items
// under a service name no other run has ever used.

/// A service name no other test run has ever used.
func isolatedService() -> String {
    "com.gerstman.niles.tests." + UUID().uuidString
}

/// Deletes every generic-password item under the service — cleanup for the
/// isolated namespace above.
func deleteAllItems(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
    ]
    SecItemDelete(query as CFDictionary)
}
