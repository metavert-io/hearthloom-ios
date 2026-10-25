import Foundation
import Security

/// The capture-only credential: a scoped key that can call
/// `POST /v1/ingest/capture` and `/health` and nothing else, plus the node it
/// belongs to.
struct CaptureCredential: Codable, Equatable {
    let baseURL: URL
    let key: String
}

/// Keychain item for the capture key — deliberately separate from
/// `KeychainStore`. The device token there is `WhenUnlocked` + user presence,
/// which the capture intent can't read when it runs from Siri or Shortcuts on a
/// locked phone. This item is `AfterFirstUnlock` with no presence check, which
/// is acceptable only because the key is write-only: it cannot read the record.
/// Never store the device token here.
enum CaptureKeyStore {
    private static let service = "com.metavert.hearthloom.capture"
    private static let account = "capture-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ credential: CaptureCredential) throws {
        let data = try JSONEncoder().encode(credential)
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStore.KeychainError.unexpectedStatus(status) }
    }

    static func load() -> CaptureCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(CaptureCredential.self, from: data)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
