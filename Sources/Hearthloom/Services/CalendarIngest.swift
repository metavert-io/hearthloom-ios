import Foundation
import EventKit

/// Calendar adapter (Tier 1). Live events → `Event` episodes + attendee `Person`
/// edges; each event location also feeds the server's unified location model.
/// Idempotent per-event by EventKit identifier; uploads to
/// `POST /v1/ingest/calendar` (`CalendarIngestConfig.streamingEnabled` pauses
/// them).
struct CalendarEventRecord: Codable, Equatable {
    let uid: String, title: String
    let start: String, end: String
    let location: String, attendees: [String]
    let tzOffsetMinutes: Int
}

enum CalendarPayload {
    static func build(actor: String, device: String, items: [CalendarEventRecord]) -> [String: Any] {
        ["actor": actor, "source": "calendar", "device": device,
         "items": items.map { e in
            ["uid": e.uid, "title": e.title, "start": e.start, "end": e.end,
             "location": e.location, "attendees": e.attendees,
             "tz_offset_minutes": e.tzOffsetMinutes] as [String: Any] }]
    }
}

enum CalendarIngestConfig { static let streamingEnabled = true }

@MainActor
final class CalendarIngest: DeviceAdapter {
    @Published private(set) var syncedCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false
    @Published private(set) var lastSyncedAt: Date? =
        UserDefaults.standard.object(forKey: "calendar.lastSyncedAt") as? Date

    private let connection: Connection
    private let store = EKEventStore()
    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }
    init(connection: Connection) { self.connection = connection }

    static let enabledKey = "calendar.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    var connected: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var statusText: String { connected ? "Connected" : "Not connected" }
    var pendingNote: String? { CalendarIngestConfig.streamingEnabled ? nil
        : "Uploading is pending the node’s /v1/ingest/calendar endpoint." }

    func connect() async {
        do {
            if try await store.requestFullAccessToEvents() {
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
                await scan()
            } else { lastError = "Calendar access denied." }
        } catch { lastError = error.localizedDescription }
    }

    func forceResync() async { syncedCount = 0; await scan() }

    func scan() async {
        guard connected else { return }
        busy = true; lastError = nil; defer { busy = false }
        let records = collect()   // EventKit calls are cheap; kept on main
        for chunk in stride(from: 0, to: records.count, by: 200).map({ Array(records[$0..<min($0+200, records.count)]) }) {
            do {
                if CalendarIngestConfig.streamingEnabled {
                    let api = self.api, pat = connection.deviceToken
                    let body = CalendarPayload.build(actor: "adapter:ios-calendar", device: "iPhone", items: chunk)
                    _ = try await IngestGate.shared.run { try await api.postIngest(path: "v1/ingest/calendar", pat: pat, body: body) }
                }
                syncedCount += chunk.count
                let now = Date(); lastSyncedAt = now
                UserDefaults.standard.set(now, forKey: "calendar.lastSyncedAt")
            } catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; return }
        }
    }

    private func collect() -> [CalendarEventRecord] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .year, value: -2, to: Date()) ?? Date()
        let end = cal.date(byAdding: .year, value: 1, to: Date()) ?? Date()
        // Predicate windows are capped to ~4 years by EventKit; our 3y span is fine.
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let tz = TimeZone.current.secondsFromGMT() / 60
        return store.events(matching: pred).map { e in
            CalendarEventRecord(
                uid: e.eventIdentifier ?? "\(e.calendarItemIdentifier)",
                title: e.title ?? "(untitled)",
                start: HearthAPI.rfc3339(e.startDate),
                end: HearthAPI.rfc3339(e.endDate),
                location: e.location ?? "",
                attendees: (e.attendees ?? []).compactMap { $0.name },
                tzOffsetMinutes: tz)
        }
    }
}
