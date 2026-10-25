import Foundation

/// Client for a Hearthloom node daemon (`hearthloom-daemon`).
///
/// The endpoints it calls are listed in docs/node-api.md; the routes live in
/// hearthloom's `crates/hearthloom-daemon/src/http.rs`. The phone talks to a
/// node exactly like the CLI/dashboard: HTTP + a scoped bearer PAT, writes
/// carrying an actor identity.
struct HearthAPI {
    let baseURL: URL

    enum APIError: LocalizedError {
        case badBaseURL
        case notReachable(String)
        case unauthorized(String)
        case server(Int, String)
        case decoding(String)
        var errorDescription: String? {
            switch self {
            case .badBaseURL: return "That doesn't look like a valid server address."
            case .notReachable(let m): return "Couldn't reach the server: \(m)"
            case .unauthorized(let m): return m
            case .server(let c, let m): return "Server error \(c): \(m)"
            case .decoding(let m): return "Unexpected server response: \(m)"
            }
        }
    }

    /// Result of a credential sign-in: a minted device PAT plus the fresh
    /// session cookies (dropped once persisted, but handed to the webview so the
    /// dashboard renders authenticated immediately).
    struct SignInResult {
        let deviceToken: String
        let sessionCookies: [HTTPCookie]
    }

    // MARK: - URL helpers

    /// Normalize a user-typed address into a base URL (adds https:// if no
    /// scheme, strips trailing slash). Loopback/host:port allowed.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.host != nil else { return nil }
        return u
    }

    private func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    // MARK: - Reachability

    /// `GET /health` — pre-auth reachability probe. Throws on non-2xx.
    func probeHealth() async throws {
        var req = URLRequest(url: url("health"))
        req.timeoutInterval = 12
        do {
            let (_, resp) = try await Self.session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw APIError.notReachable("no response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.notReachable("health returned \(http.statusCode)")
            }
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.notReachable(error.localizedDescription)
        }
    }

    // MARK: - Sign in (path 3a) + mint device PAT

    /// Full self-host credential flow: `POST /v1/auth/login {email,password}` to
    /// capture `hl_session`, then `POST /v1/keys` to mint a `read,ingest,notify`
    /// device PAT.
    func signInAndMintKey(email: String, password: String, deviceName: String) async throws -> SignInResult {
        let cookies = try await login(body: ["email": email, "password": password])
        let token = try await mintDeviceKey(sessionCookies: cookies, deviceName: deviceName)
        return SignInResult(deviceToken: token, sessionCookies: cookies)
    }

    /// hearthlaunch / issuer-token flow: `POST /v1/auth/login {issuer_token}`.
    func signInWithIssuerTokenAndMintKey(issuerToken: String, deviceName: String) async throws -> SignInResult {
        let cookies = try await login(body: ["issuer_token": issuerToken])
        let token = try await mintDeviceKey(sessionCookies: cookies, deviceName: deviceName)
        return SignInResult(deviceToken: token, sessionCookies: cookies)
    }

    /// `POST /v1/auth/login` (JSON). Returns the `hl_session` (+ any) cookies.
    /// We use a dedicated ephemeral session so we can read Set-Cookie ourselves.
    private func login(body: [String: String]) async throws -> [HTTPCookie] {
        var req = URLRequest(url: url("v1/auth/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Force the JSON contract (not the html redirect branch).
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20

        let (data, resp) = try await Self.ephemeralSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.notReachable("no response")
        }
        if http.statusCode == 401 {
            throw APIError.unauthorized(Self.message(from: data) ??
                "That didn't match — check the email and password.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, Self.message(from: data) ?? "login failed")
        }
        let cookies = Self.cookies(from: http, url: baseURL)
        guard cookies.contains(where: { $0.name == "hl_session" }) else {
            throw APIError.decoding("login succeeded but no session cookie was set")
        }
        return cookies
    }

    /// Re-establish a browser session from credentials only (no key mint) —
    /// used by the webview re-auth flow to refresh an expired `hl_session`.
    func establishSession(email: String, password: String) async throws -> [HTTPCookie] {
        try await login(body: ["email": email, "password": password])
    }

    /// Exchange the durable device PAT for a browser session
    /// (`POST /v1/auth/session-from-key`). Returns the `hl_session` cookie(s) to
    /// inject into the webview — so a device holding only a PAT can render the
    /// authenticated dashboard, and relaunches re-auth from the Keychain without
    /// a password. Requires the PAT's `read` scope (device PATs have it).
    func sessionFromKey(pat: String) async throws -> [HTTPCookie] {
        var req = URLRequest(url: url("v1/auth/session-from-key"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await Self.ephemeralSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notReachable("no response") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized("The device token was rejected.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, Self.message(from: data) ?? "session mint failed")
        }
        let cookies = Self.cookies(from: http, url: baseURL)
        guard cookies.contains(where: { $0.name == "hl_session" }) else {
            throw APIError.decoding("no session cookie returned")
        }
        return cookies
    }

    /// Probe `/v1/auth/me` with the given cookies to learn whether the webview
    /// is authenticated. Returns `(authRequired, authenticated)`.
    /// `authenticated` is true when the node reports a `user` for the session.
    func webAuthState(cookies: [HTTPCookie]) async throws -> (required: Bool, authenticated: Bool) {
        var req = URLRequest(url: url("v1/auth/me"))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let header = HTTPCookie.requestHeaderFields(with: cookies)
        for (k, v) in header { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 12
        let (data, resp) = try await Self.ephemeralSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw APIError.notReachable("auth probe failed") }
        let required = (obj["auth"] as? String) == "required"
        let authenticated = !(obj["user"] is NSNull) && obj["user"] != nil
        return (required, authenticated)
    }

    /// `POST /v1/keys` with the session cookie → returns the plaintext PAT
    /// (`secret`). Scopes locked to `read,ingest,notify`.
    private func mintDeviceKey(sessionCookies: [HTTPCookie], deviceName: String) async throws -> String {
        var req = URLRequest(url: url("v1/keys"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Attach the session cookie manually (ephemeral session, no shared jar).
        let header = HTTPCookie.requestHeaderFields(with: sessionCookies)
        for (k, v) in header { req.setValue(v, forHTTPHeaderField: k) }
        let body: [String: Any] = [
            "actor": "adapter:ios-\(Self.sanitize(deviceName))",
            "name": "\(deviceName) (Hearthloom iOS device PAT)",
            "scopes": ["read", "ingest", "notify"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20

        let (data, resp) = try await Self.ephemeralSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notReachable("no response") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized(Self.message(from: data) ??
                "This account can't mint a device key.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, Self.message(from: data) ?? "key mint failed")
        }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let secret = obj["secret"] as? String, !secret.isEmpty
        else {
            throw APIError.decoding("no secret in key-mint response")
        }
        return secret
    }

    // MARK: - Validate a pasted PAT (path 3b)

    /// Confirm a pasted PAT authenticates: `GET /v1/stats` with the Bearer token.
    /// `/v1/stats` is NOT a pre-auth route, so a 200 proves real authorization
    /// (an invalid Bearer 401s in the middleware; a missing one would 401 on a
    /// locked node). Returns the identity from `/v1/auth/me` if available.
    func validatePAT(_ pat: String) async throws {
        var req = URLRequest(url: url("v1/stats"))
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notReachable("no response") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized("That token was rejected by the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, Self.message(from: data) ?? "validation failed")
        }
    }

    // MARK: - Vault (Face ID-gated action)

    /// `POST /v1/vault {actor, action, minutes}` with the device PAT. Returns the
    /// resulting status (`{locked, seconds_remaining}`).
    @discardableResult
    func setVault(pat: String, action: String, minutes: Int, actor: String) async throws -> [String: Any] {
        var req = URLRequest(url: url("v1/vault"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["actor": actor, "action": action, "minutes": minutes]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notReachable("no response") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized("The device token was rejected.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, Self.message(from: data) ?? "vault \(action) failed")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// `GET /v1/vault` → current lock status JSON (best-effort; returns nil map on error).
    func vaultStatus(pat: String) async throws -> [String: Any] {
        var req = URLRequest(url: url("v1/vault"))
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return [:]
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Sessions & helpers

    /// RFC 3339 UTC to the second, e.g. `2026-07-23T23:30:00Z`. Shared by the
    /// HealthKit ingest payload builder.
    static func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]   // no fractional seconds
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// Shared session (uses the process cookie jar; fine for Bearer calls).
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    /// Ephemeral session with NO shared cookie jar so we own Set-Cookie parsing
    /// during the sign-in → mint handshake, then discard everything.
    static let ephemeralSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    private static func cookies(from http: HTTPURLResponse, url: URL) -> [HTTPCookie] {
        guard let fields = http.allHeaderFields as? [String: String] else { return [] }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
    }

    private static func message(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let msg = obj["error"] as? String
        else { return nil }
        return msg
    }

    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .lowercased()
    }
}
