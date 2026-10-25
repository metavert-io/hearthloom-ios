import Foundation
import CoreLocation

/// Location / Visits adapter (flagship, Track B) → `POST /v1/ingest/location`.
/// Unlike the poll-based adapters this one is **delegate-driven**: CoreLocation's
/// visit-monitoring service (`CLLocationManager.startMonitoringVisits`) delivers a
/// `CLVisit` on each arrival and again on departure, and the system relaunches the
/// app for visit events even when it isn't running (needs **Always** auth). Each
/// visit is persisted and streamed as an observation; the server clusters LOCATION
/// across sources (photos, visits, …) so we just send what we see.
///
/// Idempotency: a stable per-visit `key` (rounded coordinate + arrival epoch). A
/// visit first arrives "open" (no departure) and later "closes" with a real
/// `t_end`; re-POSTing the same key with the added `t_end` updates it — we track a
/// per-key signature so a close is resent but nothing is sent twice unchanged.
struct VisitRecord: Codable, Equatable {
    let key: String
    let lat: Double
    let lon: Double
    let accuracyM: Double?
    let tStart: String
    let tEnd: String?
    let tzOffsetMinutes: Int
    var lastSentSignature: String?
}

enum LocationPayload {
    static func build(actor: String, items: [VisitRecord]) -> [String: Any] {
        ["actor": actor, "source": "ios-visits",
         "items": items.map { v -> [String: Any] in
            var o: [String: Any] = ["key": v.key, "lat": v.lat, "lon": v.lon,
                                    "t_start": v.tStart, "tz_offset_minutes": v.tzOffsetMinutes]
            if let a = v.accuracyM { o["accuracy_m"] = a }
            if let e = v.tEnd { o["t_end"] = e }
            return o
        }]
    }
}

enum LocationIngestConfig { static let streamingEnabled = true }

@MainActor
final class LocationVisitsIngest: NSObject, ObservableObject, DeviceAdapter {
    @Published private(set) var syncedCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false
    @Published private(set) var lastSyncedAt: Date? =
        UserDefaults.standard.object(forKey: "location.lastSyncedAt") as? Date

    private let connection: Connection
    private let manager = CLLocationManager()
    private let storeKey = "location.pendingVisits"
    private var store: [String: VisitRecord] = [:]
    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }

    static let enabledKey = "location.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    init(connection: Connection) {
        self.connection = connection
        super.init()
        manager.delegate = self
        loadStore()
    }

    // MARK: - DeviceAdapter

    var connected: Bool {
        let s = manager.authorizationStatus
        return s == .authorizedAlways || s == .authorizedWhenInUse
    }

    var statusText: String {
        switch manager.authorizationStatus {
        case .authorizedAlways: return "Connected (always)"
        case .authorizedWhenInUse: return "Foreground only — enable Always for background visits"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not connected"
        @unknown default: return "Unknown"
        }
    }

    var pendingNote: String? { LocationIngestConfig.streamingEnabled ? nil
        : "Uploading is pending the node’s /v1/ingest/location endpoint." }

    var settingsHint: String? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse:
            // iOS never offers "Always" on the first prompt — the user must raise
            // it here, and visits only record in the background with Always.
            return "Visits only record in the background with “Always” location access. Tap Open Settings → Location, and choose Always."
        case .denied, .restricted:
            return "Location access is turned off for Hearthloom. Tap Open Settings to enable it."
        default:
            return nil
        }
    }

    func connect() async {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        // Visits need Always to deliver in the background / after relaunch. When
        // status is notDetermined this shows the OS prompt; if the user first
        // grants "When In Use" iOS later offers the Always upgrade.
        manager.requestAlwaysAuthorization()
        manager.startMonitoringVisits()
        await scan()
    }

    func forceResync() async {
        for (k, var r) in store { r.lastSentSignature = nil; store[k] = r }
        saveStore(); syncedCount = 0
        await scan()
    }

    /// Flush any visits whose current state hasn't been sent yet. Called on the
    /// delegate's every observation, on connect, on launch/foreground resume.
    func scan() async {
        guard Self.isEnabled else { return }
        busy = true; lastError = nil; defer { busy = false }

        let pending = store.values.filter { $0.lastSentSignature != Self.signature($0) }
        guard !pending.isEmpty else { markSynced(); return }

        let records = Array(pending)
        for chunk in stride(from: 0, to: records.count, by: 200).map({ Array(records[$0..<min($0+200, records.count)]) }) {
            do {
                if LocationIngestConfig.streamingEnabled {
                    let api = self.api, pat = connection.deviceToken
                    let body = LocationPayload.build(actor: "adapter:ios-visits", items: chunk)
                    _ = try await IngestGate.shared.run { try await api.postIngest(path: "v1/ingest/location", pat: pat, body: body) }
                }
                for var r in chunk { r.lastSentSignature = Self.signature(r); store[r.key] = r }
                saveStore()
                syncedCount += chunk.count
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }
        }
        markSynced()
    }

    /// Resume visit monitoring on launch/foreground for an already-connected user.
    func start() {
        guard Self.isEnabled else { return }
        manager.startMonitoringVisits()
    }

    // MARK: - Internals

    /// What we last sent for a key; changes when an open visit later closes.
    nonisolated static func signature(_ r: VisitRecord) -> String { r.tEnd ?? "open" }

    private func record(lat: Double, lon: Double, accuracy: Double, arrival: Date, departure: Date) {
        guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else { return }
        // arrival can be distantPast (unknown) — we need a real start for the key.
        guard arrival > Date(timeIntervalSince1970: 0) else { return }
        let end: Date? = (departure == Date.distantFuture) ? nil : departure
        let tz = TimeZone.current.secondsFromGMT() / 60
        let key = "ios-visits|\(String(format: "%.5f", lat))|\(String(format: "%.5f", lon))|\(Int(arrival.timeIntervalSince1970))"
        let rec = VisitRecord(
            key: key, lat: lat, lon: lon,
            accuracyM: accuracy > 0 ? accuracy : nil,
            tStart: HearthAPI.rfc3339(arrival),
            tEnd: end.map(HearthAPI.rfc3339),
            tzOffsetMinutes: tz,
            lastSentSignature: store[key]?.lastSentSignature)
        store[key] = rec
        saveStore()
        Task { await self.scan() }
    }

    private func loadStore() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: VisitRecord].self, from: data) else { return }
        store = decoded
    }

    private func saveStore() {
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func markSynced() {
        let now = Date(); lastSyncedAt = now
        UserDefaults.standard.set(now, forKey: "location.lastSyncedAt")
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationVisitsIngest: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // Extract Sendable value types on the delegate thread, then hop to main.
        let lat = visit.coordinate.latitude
        let lon = visit.coordinate.longitude
        let acc = visit.horizontalAccuracy
        let arrival = visit.arrivalDate
        let departure = visit.departureDate
        Task { @MainActor in
            self.record(lat: lat, lon: lon, accuracy: acc, arrival: arrival, departure: departure)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.objectWillChange.send()   // refresh statusText/connected in the UI
            let s = manager.authorizationStatus
            if s == .authorizedAlways || s == .authorizedWhenInUse {
                manager.startMonitoringVisits()
                await self.scan()
            }
        }
    }
}
