import Foundation

/// Serializes ALL device-ingest POSTs (health + photos, across every HealthKit
/// type) through one queue, so a full re-sync of one adapter doesn't flood the
/// node or starve the other. One batch in flight at a time; callers still await
/// their own result and errors, so anchors/markers only advance on real success.
actor IngestGate {
    static let shared = IngestGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }

    /// Run `op` with exclusive access; the next queued caller starts when it ends.
    func run<T>(_ op: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await op()
    }
}
