import Foundation
import CoreMotion

/// Motion/trips adapter (Tier 2) → `POST /v1/ingest/motion`. Coalesces the
/// device's activity stream into mode segments (walking/running/cycling/
/// automotive/stationary). Idempotent per segment by (mode, start);
/// `MotionIngestConfig.streamingEnabled` pauses uploads.
struct MotionRecord: Codable, Equatable {
    let key: String, mode: String
    let start: String, end: String
    let tzOffsetMinutes: Int
}

enum MotionPayload {
    static func build(actor: String, device: String, items: [MotionRecord]) -> [String: Any] {
        ["actor": actor, "source": "ios-motion", "device": device,
         "items": items.map { m in
            ["key": m.key, "mode": m.mode, "start": m.start, "end": m.end,
             "tz_offset_minutes": m.tzOffsetMinutes] as [String: Any] }]
    }
}

enum MotionIngestConfig { static let streamingEnabled = true }

@MainActor
final class MotionIngest: DeviceAdapter {
    @Published private(set) var syncedCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false
    @Published private(set) var lastSyncedAt: Date? =
        UserDefaults.standard.object(forKey: "motion.lastSyncedAt") as? Date

    private let connection: Connection
    private let manager = CMMotionActivityManager()
    private let markerKey = "motion.lastScannedEpoch"
    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }
    init(connection: Connection) { self.connection = connection }

    static let enabledKey = "motion.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    var connected: Bool { CMMotionActivityManager.authorizationStatus() == .authorized }
    var statusText: String {
        guard CMMotionActivityManager.isActivityAvailable() else { return "Unavailable" }
        return connected ? "Connected" : "Not connected"
    }
    var pendingNote: String? { MotionIngestConfig.streamingEnabled ? nil
        : "Uploading is pending the node’s /v1/ingest/motion endpoint." }

    func connect() async {
        guard CMMotionActivityManager.isActivityAvailable() else { lastError = "Motion not available."; return }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)  // first query triggers the prompt
        await scan()
    }

    func forceResync() async {
        UserDefaults.standard.removeObject(forKey: markerKey); syncedCount = 0; await scan()
    }

    func scan() async {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        busy = true; lastError = nil; defer { busy = false }

        // CoreMotion retains ~7 days of history; scan from the marker (or 7d back).
        let since = UserDefaults.standard.double(forKey: markerKey)
        let from = since > 0 ? Date(timeIntervalSince1970: since)
                             : Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let to = Date()
        let activities: [CMMotionActivity] = await withCheckedContinuation { cont in
            manager.queryActivityStarting(from: from, to: to, to: .main) { acts, _ in
                cont.resume(returning: acts ?? [])
            }
        }
        let records = Self.coalesce(activities)
        for chunk in stride(from: 0, to: records.count, by: 200).map({ Array(records[$0..<min($0+200, records.count)]) }) {
            do {
                if MotionIngestConfig.streamingEnabled {
                    let api = self.api, pat = connection.deviceToken
                    let body = MotionPayload.build(actor: "adapter:ios-motion", device: "iPhone", items: chunk)
                    _ = try await IngestGate.shared.run { try await api.postIngest(path: "v1/ingest/motion", pat: pat, body: body) }
                }
                syncedCount += chunk.count
            } catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; return }
        }
        let now = Date(); lastSyncedAt = now
        UserDefaults.standard.set(now, forKey: "motion.lastSyncedAt")
        UserDefaults.standard.set(to.timeIntervalSince1970, forKey: markerKey)
    }

    /// Merge consecutive same-mode activities into segments.
    nonisolated static func coalesce(_ acts: [CMMotionActivity]) -> [MotionRecord] {
        let tz = TimeZone.current.secondsFromGMT() / 60
        var out: [MotionRecord] = []
        var segStart: Date?
        var segMode = ""
        func mode(_ a: CMMotionActivity) -> String {
            if a.automotive { return "automotive" }
            if a.cycling { return "cycling" }
            if a.running { return "running" }
            if a.walking { return "walking" }
            if a.stationary { return "stationary" }
            return "unknown"
        }
        for a in acts where a.confidence != .low {
            let m = mode(a)
            if m != segMode {
                if let s = segStart, segMode != "", segMode != "unknown" {
                    out.append(MotionRecord(key: "\(segMode)|\(Int(s.timeIntervalSince1970))",
                        mode: segMode, start: HearthAPI.rfc3339(s),
                        end: HearthAPI.rfc3339(a.startDate), tzOffsetMinutes: tz))
                }
                segStart = a.startDate; segMode = m
            }
        }
        return out
    }
}
