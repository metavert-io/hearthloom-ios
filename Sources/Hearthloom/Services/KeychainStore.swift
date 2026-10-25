import Foundation
import LocalAuthentication
import Security

/// Keychain persistence for `Connection`s, protected by device biometrics.
///
/// The Connection JSON (which contains the device PAT) is stored with an access
/// control that requires user presence — Face ID / Touch ID, falling back to the
/// device passcode — to *read*. Writes don't require presence, so onboarding can
/// save without a second prompt right after an explicit sign-in gesture.
///
/// We pass an already-authenticated `LAContext` into reads so the app-open Face
/// ID gate and the Keychain unlock are a single prompt, not two.
enum KeychainStore {
    /// One shared service; items are keyed by the Connection `id` so multiple
    /// connections is an additive change.
    private static let service = "com.metavert.hearthloom.connections"
    /// Phase 0 stores a pointer to the single active connection id here.
    private static let activeIdKey = "com.metavert.hearthloom.activeConnectionId"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case encodingFailed
        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let s):
                return "Keychain error \(s) (\(SecCopyErrorMessageString(s, nil) as String? ?? "unknown"))"
            case .encodingFailed:
                return "Could not encode the connection."
            }
        }
    }

    // MARK: - Access control

    private static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }
        return ac
    }

    // MARK: - Save

    static func save(_ connection: Connection) throws {
        let data = try JSONEncoder().encode(connection)
        let account = connection.id.uuidString

        // Delete any existing item for this id first (idempotent upsert).
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: try accessControl(),
        ]
        // Don't force a biometric prompt on write.
        let noAuthContext = LAContext()
        noAuthContext.interactionNotAllowed = false
        addQuery[kSecUseAuthenticationContext as String] = noAuthContext

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }

        setActiveId(connection.id)
    }

    // MARK: - Load

    /// Load the single active connection. Requires the passed context to already
    /// be authenticated (see `BiometricGate`), so no second prompt appears.
    static func loadActive(context: LAContext) throws -> Connection? {
        guard let id = activeId() else { return nil }
        return try load(id: id, context: context)
    }

    static func load(id: UUID, context: LAContext) throws -> Connection? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        query[kSecUseOperationPrompt as String] = "Unlock Hearthloom"

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return try JSONDecoder().decode(Connection.self, from: data)
    }

    // MARK: - Delete

    static func delete(id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
        if activeId() == id { clearActiveId() }
    }

    /// Is there a stored connection to unlock? (No biometric prompt.)
    static var hasActiveConnection: Bool { activeId() != nil }

    /// Wipe the active connection with no biometric prompt (deletes are
    /// unauthenticated). Used by the `--uitest-reset` launch path so UI tests
    /// start from a clean, deterministic Connect screen.
    static func resetForTesting() {
        if let id = activeId() { try? delete(id: id) }
        clearActiveId()
    }

    // MARK: - Active id pointer (not secret; stored in UserDefaults)

    private static func setActiveId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: activeIdKey)
    }
    private static func clearActiveId() {
        UserDefaults.standard.removeObject(forKey: activeIdKey)
    }
    private static func activeId() -> UUID? {
        guard let s = UserDefaults.standard.string(forKey: activeIdKey) else { return nil }
        return UUID(uuidString: s)
    }
}
