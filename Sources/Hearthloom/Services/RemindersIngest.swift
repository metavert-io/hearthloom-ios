import Foundation
import EventKit

/// Reminders adapter (Tier 1) → `POST /v1/ingest/reminders`. Idempotent per
/// reminder by EventKit identifier; `RemindersIngestConfig.streamingEnabled`
/// pauses uploads.
struct ReminderRecord: Codable, Equatable {
    let uid: String, title: String
    let due: String?
    let completed: Bool
    let list: String
}

enum RemindersPayload {
    static func build(actor: String, device: String, items: [ReminderRecord]) -> [String: Any] {
        ["actor": actor, "source": "reminders", "device": device,
         "items": items.map { r -> [String: Any] in
            var d: [String: Any] = ["uid": r.uid, "title": r.title,
                                    "completed": r.completed, "list": r.list]
            if let due = r.due { d["due"] = due }
            return d
        }]
    }
}

enum RemindersIngestConfig { static let streamingEnabled = true }

@MainActor
final class RemindersIngest: DeviceAdapter {
    @Published private(set) var syncedCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false
    @Published private(set) var lastSyncedAt: Date? =
        UserDefaults.standard.object(forKey: "reminders.lastSyncedAt") as? Date

    private let connection: Connection
    private let store = EKEventStore()
    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }
    init(connection: Connection) { self.connection = connection }

    static let enabledKey = "reminders.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    var connected: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    var statusText: String { connected ? "Connected" : "Not connected" }
    var pendingNote: String? { RemindersIngestConfig.streamingEnabled ? nil
        : "Uploading is pending the node’s /v1/ingest/reminders endpoint." }

    func connect() async {
        do {
            if try await store.requestFullAccessToReminders() {
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
                await scan()
            } else { lastError = "Reminders access denied." }
        } catch { lastError = error.localizedDescription }
    }

    func forceResync() async { syncedCount = 0; await scan() }

    func scan() async {
        guard connected else { return }
        busy = true; lastError = nil; defer { busy = false }
        let records = await collect()
        for chunk in stride(from: 0, to: records.count, by: 200).map({ Array(records[$0..<min($0+200, records.count)]) }) {
            do {
                if RemindersIngestConfig.streamingEnabled {
                    let api = self.api, pat = connection.deviceToken
                    let body = RemindersPayload.build(actor: "adapter:ios-reminders", device: "iPhone", items: chunk)
                    _ = try await IngestGate.shared.run { try await api.postIngest(path: "v1/ingest/reminders", pat: pat, body: body) }
                }
                syncedCount += chunk.count
                let now = Date(); lastSyncedAt = now
                UserDefaults.standard.set(now, forKey: "reminders.lastSyncedAt")
            } catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; return }
        }
    }

    private func collect() async -> [ReminderRecord] {
        let pred = store.predicateForReminders(in: nil)
        let items: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { cont.resume(returning: $0 ?? []) }
        }
        return items.map { r in
            ReminderRecord(
                uid: r.calendarItemIdentifier,
                title: r.title ?? "(untitled)",
                due: r.dueDateComponents?.date.map(HearthAPI.rfc3339),
                completed: r.isCompleted,
                list: r.calendar?.title ?? "")
        }
    }
}
