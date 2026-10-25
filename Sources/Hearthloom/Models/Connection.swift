import Foundation

/// A resolved, authenticated connection to a single Hearthloom node.
///
/// Every onboarding path (a pairing QR, a server address + that node's sign-in
/// or a device token, or a hosted provider) resolves to one of these.
/// `deviceToken` is a node-minted PAT scoped `read,ingest,notify` (or a
/// user-supplied PAT). The whole struct is persisted in
/// the Keychain behind Face ID; the interim sign-in session (cookies) is dropped
/// once the Connection exists.
///
/// Phase 0 supports exactly one active Connection, but the storage is keyed by
/// `id` so multiple is a later addition, not a rewrite.
struct Connection: Codable, Identifiable, Equatable {
    let id: UUID
    /// Node base, e.g. `https://node.example.com` or
    /// `http://192.168.1.20:43278`. No trailing slash.
    var baseURL: URL
    /// Node-minted PAT (scopes: read,ingest,notify) or a pasted PAT.
    var deviceToken: String
    /// Human label shown in the UI.
    var displayName: String
    /// How this connection was created — affects webview auth behaviour.
    var origin: Origin

    /// The raw values are stored in the Keychain with each connection, so they
    /// never change — the two hosted-provider cases keep the names they shipped
    /// with.
    enum Origin: String, Codable {
        case selfHostSignIn                       // the node's email/password → minted PAT (+ session)
        case selfHostPastedPAT                    // a device token: typed, or from a pairing QR
        case hostedNew = "hearthlaunchNew"        // new hosted-provider account + node (issuer-token session)
        case hostedSignIn = "hearthlaunchSignIn"  // existing hosted-provider account (issuer-token session)
    }

    init(id: UUID = UUID(), baseURL: URL, deviceToken: String,
         displayName: String, origin: Origin) {
        self.id = id
        self.baseURL = baseURL
        self.deviceToken = deviceToken
        self.displayName = displayName
        self.origin = origin
    }

    /// `true` for all origins: the node's `POST /v1/auth/session-from-key` lets
    /// even a token-only connection mint a webview session from its durable
    /// device token. See `HearthAPI.sessionFromKey`.
    var canEstablishWebSession: Bool { true }
}
