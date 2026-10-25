import Foundation
import SwiftUI

/// App-level state machine and the single owner of the active `Connection`.
///
/// Phases:
///  - `.locked`         — a stored connection exists but the app is Face ID-gated.
///  - `.needsConnection`— no stored connection; show the Connect screen.
///  - `.connected`      — unlocked; show the webview shell.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case launching
        case locked
        case needsConnection
        case connected
    }

    @Published var phase: Phase = .launching
    @Published private(set) var connection: Connection?
    @Published var unlockError: String?

    /// Fresh session cookies captured during sign-in, handed to the webview so
    /// the dashboard renders authenticated immediately. Transient — never
    /// persisted (the durable credential is the Keychain PAT).
    @Published var pendingSessionCookies: [HTTPCookie] = []

    // MARK: - Launch

    func bootstrap() {
        // UI-test hook: behave as if the capture control had just been pressed.
        if ProcessInfo.processInfo.arguments.contains("--uitest-capture") { CaptureLaunch.request() }
        // UI-test hook: start from a clean, unauthenticated Connect screen.
        if ProcessInfo.processInfo.arguments.contains("--uitest-reset") {
            KeychainStore.resetForTesting()
            CaptureService.shared.forgetKey()
            CaptureStatus().reset()
            phase = .needsConnection
            return
        }
        phase = KeychainStore.hasActiveConnection ? .locked : .needsConnection
    }

    // MARK: - Unlock (Face ID app-open gate)

    func unlock() async {
        unlockError = nil
        do {
            let ctx = try await BiometricGate.evaluate(
                reason: "Unlock Hearthloom and its device token")
            guard let conn = try KeychainStore.loadActive(context: ctx) else {
                // Pointer without an item — treat as fresh.
                phase = .needsConnection
                return
            }
            connection = conn
            Observability.setNode(conn.baseURL)
            phase = .connected
        } catch {
            unlockError = error.localizedDescription
            // Stay locked; user can retry.
        }
    }

    // MARK: - Onboarding result

    /// Called when any Connect path resolves a Connection. Persists it (behind
    /// Face ID) and moves to the shell, carrying any fresh session cookies.
    func adopt(_ connection: Connection, sessionCookies: [HTTPCookie] = []) throws {
        try KeychainStore.save(connection)
        self.connection = connection
        Observability.setNode(connection.baseURL)
        self.pendingSessionCookies = sessionCookies
        self.phase = .connected
    }

    // MARK: - Disconnect

    /// Remove the connection locally. (The PAT remains revocable server-side in
    /// the dashboard API Keys list; we don't auto-revoke on disconnect.)
    func disconnect() {
        if let id = connection?.id { try? KeychainStore.delete(id: id) }
        CaptureService.shared.forgetKey()
        connection = nil
        Observability.setNode(nil)
        pendingSessionCookies = []
        phase = .needsConnection
    }

    /// Consume + clear the pending cookies (webview reads them once).
    func takeSessionCookies() -> [HTTPCookie] {
        let c = pendingSessionCookies
        pendingSessionCookies = []
        return c
    }
}
