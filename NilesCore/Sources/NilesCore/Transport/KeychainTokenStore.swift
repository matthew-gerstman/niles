import Foundation
import Security

/// One agent's permanent credential, issued at pairing time.
///
/// Tokens never expire — revocation (deleting the Keychain item) is the only
/// invalidation. `name` comes from the pairing request and is display-only;
/// the token is the whole secret.
public struct PairedAgent: Sendable, Equatable {
    public let id: UUID
    public let name: String?
    public let token: String
    public let pairedAt: Date

    public init(id: UUID, name: String?, token: String, pairedAt: Date) {
        self.id = id
        self.name = name
        self.token = token
        self.pairedAt = pairedAt
    }
}

/// Supplies the credentials guarding Niles' MCP endpoint.
///
/// The legacy single-token surface (`loadOrCreate`) bootstraps the credential set
/// and feeds the app's token display; the set-aware surface (`listAgents`,
/// `issueToken`, `revoke`) backs the auth gate and, later, the pairing flow.
public protocol TokenStoring: Sendable {
    /// The legacy single-token surface: returns the pre-pairing bearer token,
    /// creating it in the Keychain on first use. Never mints a replacement for
    /// a revoked legacy token while any per-agent token remains.
    func loadOrCreate() throws -> String

    /// Every live credential: per-agent tokens plus the legacy token, listed
    /// as an agent entry (named "Legacy token") rather than deleted.
    func listAgents() throws -> [PairedAgent]

    /// Mints and persists a fresh 256-bit token for a new agent.
    func issueToken(name: String?) throws -> PairedAgent

    /// Deletes the agent's Keychain item. Idempotent; revoking the legacy
    /// entry deletes the legacy token item.
    func revoke(id: UUID) throws
}

/// Keychain-backed store for the bearer tokens guarding Niles' MCP endpoint.
///
/// Each credential is its own generic-password item under one service:
/// per-agent tokens live at `mcp-agent-<uuid>` accounts, and the pre-pairing
/// static token keeps its `mcp-bearer-token` account. The legacy token is not
/// migrated by copying — listing it as an agent entry (same item, stable
/// synthetic id) means it can be revoked like any other agent, deleting the
/// original item. A bearer token that reorganizes the whole home must not
/// live in UserDefaults plaintext; the Keychain is one small class away, so
/// it goes there.
public struct KeychainTokenStore: TokenStoring {

    public enum TokenStoreError: Error, Equatable {
        case duplicateItem
        case keychainFailure(OSStatus)
    }

    /// Stable synthetic id under which `listAgents()` surfaces the legacy
    /// static token; revoking it deletes the legacy Keychain item.
    public static let legacyAgentID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    static let agentAccountPrefix = "mcp-agent-"
    static let legacyAgentName = "Legacy token"

    let service: String
    let legacyAccount: String

    public init(service: String = "com.gerstman.niles", legacyAccount: String = "mcp-bearer-token") {
        self.service = service
        self.legacyAccount = legacyAccount
    }

    public func loadOrCreate() throws -> String {
        let items = try readItems()

        if let legacy = items.first(where: { $0.account == legacyAccount }) {
            return legacy.token
        }
        // Legacy token revoked (or migrated away): the oldest per-agent token
        // stands in for the single-token surface. No new legacy item is
        // minted — a revoked credential must stay revoked.
        if let oldest = items
            .filter({ $0.account.hasPrefix(Self.agentAccountPrefix) })
            .min(by: { $0.pairedAt < $1.pairedAt }) {
            return oldest.token
        }
        // Fresh install: bootstrap the legacy item — the pre-pairing credential
        // surface the app display and existing agents expect.
        let token = try Self.generateToken()
        do {
            try save(token, account: legacyAccount, label: nil)
            return token
        } catch TokenStoreError.duplicateItem {
            // Another instantiation created it first (two starts in one launch);
            // the stored token is the authoritative one.
            guard let existing = try legacyToken() else {
                throw TokenStoreError.keychainFailure(errSecDuplicateItem)
            }
            return existing
        }
    }

    public func listAgents() throws -> [PairedAgent] {
        try readItems().compactMap { item in
            if item.account == legacyAccount {
                return PairedAgent(
                    id: Self.legacyAgentID,
                    name: Self.legacyAgentName,
                    token: item.token,
                    pairedAt: item.pairedAt
                )
            }
            guard item.account.hasPrefix(Self.agentAccountPrefix) else { return nil }
            guard let id = UUID(uuidString: String(item.account.dropFirst(Self.agentAccountPrefix.count))) else {
                // Not an item this store wrote (unknown shape under our service);
                // leaving it unlisted is safer than showing an unusable entry.
                return nil
            }
            return PairedAgent(
                id: id,
                name: item.label,
                token: item.token,
                pairedAt: item.pairedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.pairedAt != rhs.pairedAt { return lhs.pairedAt < rhs.pairedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func issueToken(name: String?) throws -> PairedAgent {
        let id = UUID()
        let token = try Self.generateToken()
        try save(token, account: Self.agentAccountPrefix + id.uuidString, label: name)
        return PairedAgent(id: id, name: name, token: token, pairedAt: Date())
    }

    public func revoke(id: UUID) throws {
        let account = id == Self.legacyAgentID ? legacyAccount : Self.agentAccountPrefix + id.uuidString
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        // Not-found is fine: revocation is idempotent, and the entry is gone
        // either way.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychainFailure(status)
        }
    }

    // MARK: - Keychain plumbing

    private func legacyToken() throws -> String? {
        var query = baseQuery(account: legacyAccount)
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

    /// One service-wide read feeding both `loadOrCreate` and `listAgents`:
    /// every generic password under the service, with attributes and data.
    private func readItems() throws -> [KeychainItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let dicts = result as? [[String: Any]] else {
                throw TokenStoreError.keychainFailure(status)
            }
            return dicts.compactMap { dict in
                guard
                    let account = dict[kSecAttrAccount as String] as? String,
                    let data = dict[kSecValueData as String] as? Data
                else { return nil }
                return KeychainItem(
                    account: account,
                    label: dict[kSecAttrLabel as String] as? String,
                    token: String(decoding: data, as: UTF8.self),
                    pairedAt: dict[kSecAttrCreationDate as String] as? Date ?? Date()
                )
            }
        case errSecItemNotFound:
            return []
        default:
            throw TokenStoreError.keychainFailure(status)
        }
    }

    private func save(_ token: String, account: String, label: String?) throws {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let label {
            // Display-only metadata; identity is class + service + account.
            query[kSecAttrLabel as String] = label
        }

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

    private func baseQuery(account: String) -> [String: Any] {
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

/// One generic-password item as `listAgents` and `loadOrCreate` see it.
private struct KeychainItem {
    let account: String
    let label: String?
    let token: String
    let pairedAt: Date
}
