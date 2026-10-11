import Foundation
#if canImport(Security)
import Security
#endif

/// The signed-in account on this device. Tokens never leave the Keychain and are never logged.
public struct CommunitySession: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let userID: String
    public let email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: String, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
        self.email = email
    }
}

public protocol CommunitySessionStore: Sendable {
    func load() throws -> CommunitySession?
    func save(_ session: CommunitySession) throws
    func clear() throws
}

/// Keeps the session in memory only. Used by tests and by previews.
public final class InMemoryCommunitySessionStore: CommunitySessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: CommunitySession?

    public init(_ session: CommunitySession? = nil) {
        self.session = session
    }

    public func load() throws -> CommunitySession? {
        lock.withLock { session }
    }

    public func save(_ session: CommunitySession) throws {
        lock.withLock { self.session = session }
    }

    public func clear() throws {
        lock.withLock { session = nil }
    }
}

#if canImport(Security)
/// Keeps the session in the Keychain as one generic password, readable only after the first unlock
/// and only on this device, so it is never copied to a backup or another device.
public struct KeychainCommunitySessionStore: CommunitySessionStore {
    private let service: String
    private let account = "session"

    public init(service: String = "communityaccount") {
        self.service = service
    }

    public func load() throws -> CommunitySession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return try Self.decodeLoadResult(status: status, data: item as? Data)
    }

    public func save(_ session: CommunitySession) throws {
        let data = try JSONEncoder().encode(session)
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemDelete(baseQuery() as CFDictionary)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw CommunityError.storage
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        try Self.validateDeleteStatus(status)
    }

    static func validateDeleteStatus(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CommunityError.storage
        }
    }

    static func decodeLoadResult(status: OSStatus, data: Data?) throws -> CommunitySession? {
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else { throw CommunityError.storage }
        do {
            return try JSONDecoder().decode(CommunitySession.self, from: data)
        } catch {
            throw CommunityError.storage
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
#endif
