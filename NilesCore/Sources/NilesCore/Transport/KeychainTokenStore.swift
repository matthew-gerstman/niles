import Foundation
import Security

/// Supplies the MCP server's bearer token, creating it in the Keychain on first use.
public protocol TokenStoring: Sendable {
    func loadOrCreate() throws -> String
}

/// Keychain-backed store for the single bearer token guarding Niles' MCP endpoint.
///
/// A bearer token that reorganizes the whole home must not live in UserDefaults
/// plaintext; the Keychain is one small class away, so it goes there.
public struct KeychainTokenStore: TokenStoring {

    public enum TokenStoreError: Error, Equatable {
        case duplicateItem
        case keychainFailure(OSStatus)
    }

    let service: String
    let account: String

    public init(service: String = "com.gerstman.niles", account: String = "mcp-bearer-token") {
        self.service = service
        self.account = account
    }

    public func loadOrCreate() throws -> String {
        if let existing = try load() { return existing }
        let token = try Self.generateToken()
        do {
            try save(token)
            return token
        } catch TokenStoreError.duplicateItem {
            // Another instantiation created it first (two starts in one launch);
            // the stored token is the authoritative one.
            guard let existing = try load() else {
                throw TokenStoreError.keychainFailure(errSecDuplicateItem)
            }
            return existing
        }
    }

    private func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw TokenStoreError.keychainFailure(status)
            }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError.keychainFailure(status)
        }
    }

    private func save(_ token: String) throws {
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw TokenStoreError.duplicateItem
        default:
            throw TokenStoreError.keychainFailure(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 32 random bytes as 64 hex characters — 256 bits of entropy for a token
    /// that must survive brute-force scans of an open LAN port.
    static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TokenStoreError.keychainFailure(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
