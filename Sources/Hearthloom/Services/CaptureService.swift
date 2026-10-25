import CoreLocation
import Foundation
import UIKit

/// One-tap capture (Track B, **user-driven**) → `POST /v1/ingest/capture`.
/// A thought is queued first (`CaptureQueue`) and uploaded after, so capturing
/// never fails because of the network. Unlike the other adapters the upload has
/// to work with no user present (Siri/Shortcuts on a locked phone), so it uses
/// the write-only capture key from `CaptureKeyStore` rather than the
/// biometric-gated device token.
///
/// Gating: there is no compile-time `streamingEnabled` switch to flip when the
/// server ships. The node itself is the gate — a 404 marks the endpoint
/// unavailable and uploads back off until it answers something else.
enum CaptureIngestConfig {
    static let maxCharacters = 8_000          // server limit; over it is a 400
    static let unavailableRetry: TimeInterval = 15 * 60
    static let mintRetry: TimeInterval = 60 * 60
    /// How long the capture intent waits on an upload before answering.
    static let intentUploadBudget: TimeInterval = 6
}

struct CaptureDrainResult: Equatable {
    var uploaded = 0
    var dropped = 0
    var dropReason: String?
    /// Why the drain stopped with items still queued (nil = queue emptied).
    var stoppedBy: HearthAPI.CaptureError?
}

enum CaptureDrain {
    /// Upload the queue oldest-first. An item leaves the queue only on success
    /// (incl. a server-side duplicate) or a 400; anything else stops the drain
    /// with the item still queued, since the rest would fail the same way.
    static func run(queue: CaptureQueue,
                    post: (CaptureItem) async throws -> HearthAPI.CaptureReply) async -> CaptureDrainResult {
        var result = CaptureDrainResult()
        for item in queue.all() {
            do {
                _ = try await post(item)
                queue.remove(clientRef: item.clientRef)
                result.uploaded += 1
            } catch HearthAPI.CaptureError.rejected(let reason) {
                queue.remove(clientRef: item.clientRef)
                result.dropped += 1
                result.dropReason = reason
            } catch let error as HearthAPI.CaptureError {
                result.stoppedBy = error
                break
            } catch {
                result.stoppedBy = .transient(error.localizedDescription)
                break
            }
        }
        return result
    }

    /// Delay before the next automatic attempt after `failures` consecutive
    /// retryable failures: 30s doubling, capped at an hour.
    static func backoff(failures: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(failures - 1, 0))), 3600)
    }
}

/// Capture's persisted status, shared by the intent (writer, possibly with no
/// UI running) and the Settings screen (reader). Not secret → UserDefaults.
struct CaptureStatus {
    var defaults: UserDefaults = .standard

    static let changed = Notification.Name("capture.statusChanged")

    var uploadedCount: Int {
        get { defaults.integer(forKey: "capture.count") }
        nonmutating set { defaults.set(newValue, forKey: "capture.count") }
    }
    var lastUploadAt: Date? {
        get { defaults.object(forKey: "capture.lastUploadAt") as? Date }
        nonmutating set { defaults.set(newValue, forKey: "capture.lastUploadAt") }
    }
    var lastError: String? {
        get { defaults.string(forKey: "capture.lastError") }
        nonmutating set { defaults.set(newValue, forKey: "capture.lastError") }
    }
    /// A capture the node refused outright (400) and that was dropped.
    var lastDropped: String? {
        get { defaults.string(forKey: "capture.lastDropped") }
        nonmutating set { defaults.set(newValue, forKey: "capture.lastDropped") }
    }
    /// The capture key got a 401/403 — needs re-creating.
    var keyRejected: Bool {
        get { defaults.bool(forKey: "capture.keyRejected") }
        nonmutating set { defaults.set(newValue, forKey: "capture.keyRejected") }
    }
    /// The node answered 404 for capture (or can't mint scoped keys) last time.
    var endpointUnavailable: Bool {
        get { defaults.bool(forKey: "capture.endpointUnavailable") }
        nonmutating set { defaults.set(newValue, forKey: "capture.endpointUnavailable") }
    }
    var failures: Int {
        get { defaults.integer(forKey: "capture.failures") }
        nonmutating set { defaults.set(newValue, forKey: "capture.failures") }
    }
    var nextAttemptAt: Date? {
        get { defaults.object(forKey: "capture.nextAttemptAt") as? Date }
        nonmutating set { defaults.set(newValue, forKey: "capture.nextAttemptAt") }
    }
    var lastMintAttemptAt: Date? {
        get { defaults.object(forKey: "capture.lastMintAttemptAt") as? Date }
        nonmutating set { defaults.set(newValue, forKey: "capture.lastMintAttemptAt") }
    }

    /// Fold one drain's outcome into the status (counts, error, backoff).
    func record(_ result: CaptureDrainResult, now: Date = Date()) {
        if result.uploaded > 0 {
            uploadedCount += result.uploaded
            lastUploadAt = now
        }
        if result.dropped > 0 { lastDropped = result.dropReason ?? "refused by the node" }
        switch result.stoppedBy {
        case nil:
            lastError = nil; failures = 0; nextAttemptAt = nil
            if result.uploaded > 0 { endpointUnavailable = false; keyRejected = false }
        case .unauthorized?:
            keyRejected = true
            lastError = result.stoppedBy?.errorDescription
        case .endpointUnavailable?:
            endpointUnavailable = true
            lastError = nil   // shown as a state, not an error
            nextAttemptAt = now.addingTimeInterval(CaptureIngestConfig.unavailableRetry)
        case let error?:
            failures += 1
            lastError = error.errorDescription
            nextAttemptAt = now.addingTimeInterval(CaptureDrain.backoff(failures: failures))
        }
    }

    func reset() {
        for key in ["count", "lastUploadAt", "lastError", "lastDropped", "keyRejected",
                    "endpointUnavailable", "failures", "nextAttemptAt", "lastMintAttemptAt"] {
            defaults.removeObject(forKey: "capture.\(key)")
        }
    }
}

enum CaptureInputError: LocalizedError, Equatable {
    case empty
    case tooLong
    var errorDescription: String? {
        switch self {
        case .empty: return "There’s nothing to capture."
        case .tooLong: return "That’s too long to capture (8,000 characters at most)."
        }
    }
}

/// Owns capture's side effects: queueing, the single-flight drain, and the
/// capture key. An actor so the intent and the app can't run two drains at once.
actor CaptureService {
    static let shared = CaptureService()

    private let queue = CaptureQueue.shared
    private let status = CaptureStatus()
    private var draining: Task<CaptureDrainResult?, Never>?

    // MARK: - Capture

    /// Validate and queue a thought. Succeeds as soon as it is on disk; upload
    /// is a separate step. Location is attached only when already permitted.
    @discardableResult
    nonisolated func capture(text: String, at date: Date = Date()) async throws -> CaptureItem {
        let trimmed = try Self.validate(text)
        let place = await Self.permittedLocation(now: date)
        let item = CaptureItem(text: trimmed, capturedAt: date, lat: place?.latitude, lon: place?.longitude)
        try queue.append(item)
        Self.announce()
        return item
    }

    static func validate(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaptureInputError.empty }
        guard trimmed.count <= CaptureIngestConfig.maxCharacters else { throw CaptureInputError.tooLong }
        return trimmed
    }

    /// The last known position, only if the user has ALREADY granted location
    /// to the app and the fix is recent. Never prompts and never starts updates.
    /// Core Location's getters are synchronous and can block, so they run off
    /// the main thread and capture waits at most a second for them — a thought
    /// is worth more than its pin.
    private static func permittedLocation(now: Date) async -> (latitude: Double, longitude: Double)? {
        await Race.first(within: 1) { () async -> (latitude: Double, longitude: Double)? in
            await withCheckedContinuation { done in
                DispatchQueue.global(qos: .userInitiated).async {
                    let manager = CLLocationManager()
                    let auth = manager.authorizationStatus
                    guard auth == .authorizedAlways || auth == .authorizedWhenInUse,
                          let fix = manager.location, now.timeIntervalSince(fix.timestamp) < 600,
                          CLLocationCoordinate2DIsValid(fix.coordinate) else { return done.resume(returning: nil) }
                    done.resume(returning: (fix.coordinate.latitude, fix.coordinate.longitude))
                }
            }
        } ?? nil
    }

    // MARK: - Drain

    /// Upload whatever is queued. Automatic callers respect the backoff window;
    /// `force` (a user tapping "Upload now") does not. `connection` is the
    /// unlocked app's device token, used only when there is no usable capture
    /// key (its `ingest` scope is accepted too). Returns nil when nothing ran.
    @discardableResult
    func drain(force: Bool = false, connection: Connection? = nil) async -> CaptureDrainResult? {
        if let draining { return await draining.value }
        let task = Task { await self.runDrain(force: force, connection: connection) }
        draining = task
        let result = await task.value
        draining = nil
        return result
    }

    /// `drain`, but stop WAITING after `budget` seconds — for the intent, which
    /// must answer promptly. The upload is left running rather than cancelled:
    /// it may still land, and if it doesn't the item is simply still queued.
    nonisolated func drain(budget: TimeInterval) async {
        _ = await Race.first(within: budget) { await self.drain() != nil }
    }

    private func runDrain(force: Bool, connection: Connection?) async -> CaptureDrainResult? {
        guard queue.count > 0 else { return nil }
        if !force, let next = status.nextAttemptAt, next > Date() { return nil }
        guard let (api, token) = credential(connection: connection) else { return nil }
        Observability.setNode(api.baseURL)   // the capture key's node is the connected one
        let result = await CaptureDrain.run(queue: queue) { item in
            try await IngestGate.shared.run { try await api.postCapture(token: token, item: item) }
        }
        status.record(result)
        Self.announce()
        return result
    }

    /// The capture key if it's usable; otherwise the unlocked app's device token.
    private func credential(connection: Connection?) -> (HearthAPI, String)? {
        if let stored = CaptureKeyStore.load(), !status.keyRejected,
           connection == nil || connection?.baseURL == stored.baseURL {
            return (HearthAPI(baseURL: stored.baseURL), stored.key)
        }
        guard let connection else { return nil }
        return (HearthAPI(baseURL: connection.baseURL), connection.deviceToken)
    }

    // MARK: - Capture key

    /// Make sure a capture key exists for this connection, minting one with the
    /// device token if needed. Automatic attempts are spaced out so a node
    /// without scoped keys isn't asked on every foreground; `force` re-mints.
    /// Returns a user-facing error, or nil.
    @discardableResult
    func ensureKey(connection: Connection, force: Bool = false) async -> String? {
        let stored = CaptureKeyStore.load()
        if let stored, stored.baseURL != connection.baseURL { CaptureKeyStore.delete() }
        else if stored != nil, !force, !status.keyRejected { return nil }
        if !force, let last = status.lastMintAttemptAt,
           Date().timeIntervalSince(last) < CaptureIngestConfig.mintRetry { return nil }
        status.lastMintAttemptAt = Date()
        defer { Self.announce() }
        do {
            let name = await UIDevice.current.name
            let key = try await HearthAPI(baseURL: connection.baseURL)
                .mintCaptureKey(pat: connection.deviceToken, deviceName: name)
            try CaptureKeyStore.save(CaptureCredential(baseURL: connection.baseURL, key: key))
            status.keyRejected = false
            status.endpointUnavailable = false
            status.nextAttemptAt = nil
            if status.lastError == HearthAPI.CaptureError.unauthorized.errorDescription { status.lastError = nil }
            return nil
        } catch is HearthAPI.EndpointUnavailable {
            status.endpointUnavailable = true
            return HearthAPI.CaptureError.endpointUnavailable.errorDescription
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Forget the capture key (disconnect). Queued captures are kept — they are
    /// the user's thoughts and upload to whichever node is connected next.
    nonisolated func forgetKey() {
        CaptureKeyStore.delete()
        let status = CaptureStatus()
        status.keyRejected = false
        status.endpointUnavailable = false
        status.lastMintAttemptAt = nil
        status.nextAttemptAt = nil
        Self.announce()
    }

    private static func announce() {
        NotificationCenter.default.post(name: CaptureStatus.changed, object: nil)
    }
}

/// Wait for an operation, but only so long.
enum Race {
    /// `op`'s value, or nil if it hasn't finished within `seconds`. The
    /// operation is NOT cancelled — it keeps running; we just stop waiting.
    /// (Unstructured on purpose: a task group would wait for the slow child.)
    static func first<T: Sendable>(within seconds: TimeInterval,
                                   _ op: @escaping @Sendable () async -> T) async -> T? {
        let once = Once<T?>()
        return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            Task { once.resume(done, with: await op()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(done, with: nil)
            }
        }
    }

    private final class Once<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func resume(_ continuation: CheckedContinuation<Value, Never>, with value: Value) {
            let first = lock.withLock { () -> Bool in defer { resumed = true }; return !resumed }
            if first { continuation.resume(returning: value) }
        }
    }
}
