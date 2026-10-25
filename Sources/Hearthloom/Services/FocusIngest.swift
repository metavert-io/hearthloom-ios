import Foundation
import Intents

/// Focus adapter (Track B) → `POST /v1/ingest/focus`. Records spans of a Focus
/// being on as `{key, state, since, until?}`; re-POSTing a key with `until` closes
/// its span (server contract).
///
/// Fidelity: the high-signal path is the **Focus Filter App Intent**
/// (`HearthloomFocusFilter`) — once the user adds Hearthloom as a filter to a
/// Focus, the system background-runs it on every on/off with the mode label, and
/// those land in `FocusEventStore`. `scan()` (on launch/foreground) drains them
/// into spans. `INFocusStatusCenter` is kept only as a **backstop** to close a
/// span if we ever miss a deactivation.
struct FocusSpan: Codable, Equatable {
    let key: String
    let state: String        // the Focus mode label, e.g. "Work"
    let since: String
    var until: String?
    var openSent: Bool
    var closedSent: Bool
}

enum FocusPayload {
    static func build(actor: String, device: String, items: [FocusSpan]) -> [String: Any] {
        ["actor": actor, "source": "ios-focus", "device": device,
         "items": items.map { s -> [String: Any] in
            var o: [String: Any] = ["key": s.key, "state": s.state, "since": s.since]
            if let u = s.until { o["until"] = u }
            return o
        }]
    }
}

enum FocusIngestConfig { static let streamingEnabled = true }

@MainActor
final class FocusIngest: DeviceAdapter {
    @Published private(set) var syncedCount =
        UserDefaults.standard.integer(forKey: "focus.count")
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false
    @Published private(set) var lastSyncedAt: Date? =
        UserDefaults.standard.object(forKey: "focus.lastSyncedAt") as? Date

    private let connection: Connection
    private let currentKey = "focus.currentSpan"
    private var current: FocusSpan?
    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }

    init(connection: Connection) {
        self.connection = connection
        if let data = UserDefaults.standard.data(forKey: currentKey),
           let span = try? JSONDecoder().decode(FocusSpan.self, from: data) {
            current = span
        }
    }

    static let enabledKey = "focus.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    var connected: Bool { Self.isEnabled }
    var statusText: String { Self.isEnabled ? "Connected" : "Not connected" }
    var pendingNote: String? {
        "For background, mode-aware capture, add Hearthloom as a Focus Filter: Settings → Focus → (a Focus) → Focus Filters → Hearthloom. Changes also sync whenever you open the app."
    }

    func connect() async {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        // Best-effort — used only by the foreground reconcile backstop below.
        _ = await withCheckedContinuation { (cont: CheckedContinuation<INFocusStatusAuthorizationStatus, Never>) in
            INFocusStatusCenter.default.requestAuthorization { cont.resume(returning: $0) }
        }
        await scan()
    }

    func forceResync() async {
        current = nil
        UserDefaults.standard.removeObject(forKey: currentKey)
        syncedCount = 0
        UserDefaults.standard.set(0, forKey: "focus.count")
        await scan()
    }

    /// Drain Focus-filter events into open/close spans, then reconcile.
    func scan() async {
        guard Self.isEnabled else { return }
        busy = true; lastError = nil; defer { busy = false }

        for event in FocusEventStore.drain() {
            if event.on {
                await openSpan(mode: event.mode, since: event.at)   // closes any prior span first
            } else {
                await closeOpenSpan(until: event.at)
            }
        }

        // Backstop: if the OS reports no active Focus but we still hold an open
        // span (a deactivation the intent didn't deliver), close it now.
        if INFocusStatusCenter.default.authorizationStatus == .authorized,
           let isFocused = INFocusStatusCenter.default.focusStatus.isFocused, !isFocused {
            await closeOpenSpan(until: Date())
        }
        markSynced()
    }

    // MARK: - Spans

    private func openSpan(mode: String, since: Date) async {
        await closeOpenSpan(until: since)   // never leave two spans open at once
        let span = FocusSpan(key: "focus|\(Int(since.timeIntervalSince1970))|\(mode)",
                             state: mode, since: HearthAPI.rfc3339(since),
                             until: nil, openSent: false, closedSent: false)
        current = span; persist()
        if let updated = await post(span) { current = updated; persist() }
    }

    private func closeOpenSpan(until: Date) async {
        guard var span = current else { return }
        span.until = HearthAPI.rfc3339(until)
        // The close POST carries since AND until, so it records the full span even
        // if the open POST had failed. Idempotent per key.
        if await post(span) != nil {
            current = nil
            UserDefaults.standard.removeObject(forKey: currentKey)
        }
    }

    /// POST one span; on success flags open/closed sent and bumps the count.
    /// Returns the updated span, or nil on failure.
    private func post(_ span: FocusSpan) async -> FocusSpan? {
        do {
            if FocusIngestConfig.streamingEnabled {
                let api = self.api, pat = connection.deviceToken
                let body = FocusPayload.build(actor: "adapter:ios-focus", device: "iPhone", items: [span])
                _ = try await IngestGate.shared.run { try await api.postIngest(path: "v1/ingest/focus", pat: pat, body: body) }
            }
            var s = span
            if s.until == nil { s.openSent = true } else { s.closedSent = true }
            syncedCount += 1
            UserDefaults.standard.set(syncedCount, forKey: "focus.count")
            return s
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    private func persist() {
        if let span = current, let data = try? JSONEncoder().encode(span) {
            UserDefaults.standard.set(data, forKey: currentKey)
        }
    }

    private func markSynced() {
        let now = Date(); lastSyncedAt = now
        UserDefaults.standard.set(now, forKey: "focus.lastSyncedAt")
    }
}
