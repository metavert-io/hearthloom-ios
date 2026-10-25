import Foundation

/// Shared vault lock state so the tab bar and the Vault screen agree. Reflects
/// the node's `{locked, seconds_remaining}` and auto-flips back to locked when
/// the server-side unlock window elapses.
@MainActor
final class VaultStatus: ObservableObject {
    @Published private(set) var locked = true
    @Published private(set) var secondsRemaining = 0

    private let connection: Connection
    private var relockTask: Task<Void, Never>?
    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }

    init(connection: Connection) { self.connection = connection }

    /// Pull current status from the node (best-effort).
    func refresh() async {
        let s = try? await api.vaultStatus(pat: connection.deviceToken)
        apply(s ?? [:])
    }

    /// Update from a `{locked, seconds_remaining}` payload (e.g. a vault action
    /// response) and schedule an auto-relock refresh at expiry.
    func apply(_ status: [String: Any]) {
        if let l = status["locked"] as? Bool { locked = l }
        secondsRemaining = status["seconds_remaining"] as? Int ?? 0
        relockTask?.cancel()
        if !locked, secondsRemaining > 0 {
            let wait = secondsRemaining
            relockTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000 + 500_000_000)
                await self?.refresh()
            }
        }
    }
}
