import Foundation
import Contacts

/// Contacts adapter (Tier 1 backbone). Feeds the address book to the node so its
/// attribute-first identity resolution (email/phone owns a Person) has a canonical
/// directory. Metadata only. Idempotent per-contact by stable identifier;
/// uploads to `POST /v1/ingest/contacts` (`ContactsIngestConfig.streamingEnabled`
/// pauses them).
struct ContactRecord: Codable, Equatable {
    let key: String, name: String
    let emails: [String], phones: [String]
    let org: String, postal: [String]
}

enum ContactsPayload {
    static func build(actor: String, device: String, items: [ContactRecord]) -> [String: Any] {
        ["actor": actor, "source": "contacts", "device": device,
         "items": items.map { c in
            ["key": c.key, "name": c.name, "emails": c.emails, "phones": c.phones,
             "org": c.org, "postal": c.postal] as [String: Any] }]
    }
}

enum ContactsIngestConfig { static let streamingEnabled = true }

@MainActor
final class ContactsIngest: DeviceAdapter {
    @Published private(set) var syncedCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false
    @Published private(set) var lastSyncedAt: Date? =
        UserDefaults.standard.object(forKey: "contacts.lastSyncedAt") as? Date

    private let connection: Connection
    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }
    init(connection: Connection) { self.connection = connection }

    static let enabledKey = "contacts.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    var connected: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }
    var statusText: String { connected ? "Connected" : "Not connected" }
    var pendingNote: String? { ContactsIngestConfig.streamingEnabled ? nil
        : "Uploading is pending the node’s /v1/ingest/contacts endpoint." }

    func connect() async {
        do {
            if try await CNContactStore().requestAccess(for: .contacts) {
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
                await scan()
            } else { lastError = "Contacts access denied." }
        } catch { lastError = error.localizedDescription }
    }

    func forceResync() async { syncedCount = 0; await scan() }

    func scan() async {
        guard connected else { return }
        busy = true; lastError = nil; defer { busy = false }
        let records = await Task.detached(priority: .utility) { Self.collect() }.value
        for chunk in stride(from: 0, to: records.count, by: 200).map({ Array(records[$0..<min($0+200, records.count)]) }) {
            do {
                if ContactsIngestConfig.streamingEnabled {
                    let api = self.api, pat = connection.deviceToken
                    let body = ContactsPayload.build(actor: "adapter:ios-contacts", device: "iPhone", items: chunk)
                    _ = try await IngestGate.shared.run { try await api.postIngest(path: "v1/ingest/contacts", pat: pat, body: body) }
                }
                syncedCount += chunk.count
                let now = Date(); lastSyncedAt = now
                UserDefaults.standard.set(now, forKey: "contacts.lastSyncedAt")
            } catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; return }
        }
    }

    nonisolated private static func collect() -> [ContactRecord] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactPostalAddressesKey
        ].map { $0 as CNKeyDescriptor }
        let req = CNContactFetchRequest(keysToFetch: keys)
        var out: [ContactRecord] = []
        try? CNContactStore().enumerateContacts(with: req) { c, _ in
            let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            out.append(ContactRecord(
                key: c.identifier,
                name: name.isEmpty ? c.organizationName : name,
                emails: c.emailAddresses.map { $0.value as String },
                phones: c.phoneNumbers.map { $0.value.stringValue },
                org: c.organizationName,
                postal: c.postalAddresses.map { CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ") }))
        }
        return out
    }
}
