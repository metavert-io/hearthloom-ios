import Foundation

/// Client for a hosted provider's account API — a service that runs Hearthloom
/// nodes for its users. The app calls it only after you choose that provider on
/// the Connect screen: sign in (or create an account), answer a TOTP challenge
/// if the account has one, pick a workspace, find or create your node, and get
/// a short-lived login token for it. From then on the app talks to the node
/// alone. The API is described in docs/node-api.md ("Hosted provider API").
///
/// Auth = the account's `accessToken` (Bearer) + `X-Tenant-ID` on `/api/saas/*`.
/// There is no default provider: the caller always passes the base URL.
struct HostedProviderClient {
    let base: URL

    init(base: URL) { self.base = base }

    // MARK: - Types

    struct Membership: Equatable, Identifiable {
        let tenantId: String
        let tenantName: String
        let tenantSlug: String
        let role: String
        let isRoot: Bool
        var id: String { tenantId }
    }

    struct AuthSession: Equatable {
        let accessToken: String
        let memberships: [Membership]
        /// Root membership (a new account's own tenant) or the first available.
        var defaultTenant: Membership? { memberships.first(where: \.isRoot) ?? memberships.first }
    }

    /// A login can either succeed or demand a TOTP second factor.
    enum AuthOutcome: Equatable {
        case authenticated(AuthSession)
        case mfaRequired(mfaToken: String)
    }

    /// Bearer + chosen tenant, for `/api/saas/*` calls.
    struct Auth { let accessToken: String; let tenantId: String }

    struct InstanceSummary: Equatable, Identifiable {
        let id: String
        let name: String
        let url: URL?
        let ready: Bool
        let status: String
    }

    struct OpenedInstance { let url: URL; let issuerToken: String }

    enum ProviderError: LocalizedError {
        case http(Int, String)
        case decoding(String)
        case noTenant
        case noInstance
        var errorDescription: String? {
            switch self {
            case .http(let c, let m): return "The provider returned an error (\(c)): \(m)"
            case .decoding(let m): return "Unexpected response from the provider: \(m)"
            case .noTenant: return "This account isn't a member of any workspace yet."
            case .noInstance: return "No Hearthloom found on this account. Create one first."
            }
        }
    }

    // MARK: - Account auth

    /// `POST /api/auth/login` — an existing account. Handles the MFA branch:
    /// an account with TOTP returns `{mfaRequired, mfaToken}` and no accessToken.
    func login(email: String, password: String) async throws -> AuthOutcome {
        let (data, http) = try await post(path: "api/auth/login",
                                          body: ["email": email, "password": password], auth: nil)
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(http.statusCode, Self.message(data))
        }
        return try Self.parseAuthOutcome(data)
    }

    /// `POST /api/auth/register` — a new account.
    func register(email: String, password: String, displayName: String) async throws -> AuthSession {
        let (data, http) = try await post(path: "api/auth/register",
            body: ["email": email, "password": password, "displayName": displayName], auth: nil)
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(http.statusCode, Self.message(data))
        }
        guard case .authenticated(let session) = try Self.parseAuthOutcome(data) else {
            throw ProviderError.decoding("registration returned an MFA challenge")
        }
        return session
    }

    /// `POST /api/auth/mfa/challenge {mfaToken, code}` — complete the TOTP step.
    func mfaChallenge(mfaToken: String, code: String) async throws -> AuthSession {
        let (data, http) = try await post(path: "api/auth/mfa/challenge",
            body: ["mfaToken": mfaToken, "code": code], auth: nil)
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(http.statusCode, Self.message(data))
        }
        guard case .authenticated(let session) = try Self.parseAuthOutcome(data) else {
            throw ProviderError.decoding("MFA challenge did not return a session")
        }
        return session
    }

    // MARK: - Provision + list + open

    /// `POST /api/saas/instances {name}` → 202; caller polls `instance(id:)`.
    func provision(name: String, auth: Auth) async throws -> String {
        let (data, http) = try await post(path: "api/saas/instances", body: ["name": name], auth: auth)
        guard http.statusCode == 202 || (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(http.statusCode, Self.message(data))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { throw ProviderError.decoding("no instance id") }
        return id
    }

    /// `GET /api/saas/instances` — the member's instances (finds the node to open).
    func listInstances(auth: Auth) async throws -> [InstanceSummary] {
        let (data, http) = try await get(path: "api/saas/instances", auth: auth)
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(http.statusCode, Self.message(data))
        }
        return Self.parseInstances(data)
    }

    /// `GET /api/saas/instances/{id}` — status poll. Returns (ready, url?).
    func instance(id: String, auth: Auth) async throws -> (ready: Bool, url: URL?) {
        let (data, http) = try await get(path: "api/saas/instances/\(id)", auth: auth)
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(http.statusCode, Self.message(data))
        }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let ready = (obj["ready"] as? Bool) ?? (obj["status"] as? String == "ready")
        let url = (obj["url"] as? String).flatMap(URL.init(string:))
        return (ready, url)
    }

    /// `POST /api/saas/instances/{id}/open` → `{url, issuerToken}` (5-min TTL,
    /// 60/hr limit — call once per session, never in a poll loop).
    func open(id: String, auth: Auth) async throws -> OpenedInstance {
        let (data, http) = try await post(path: "api/saas/instances/\(id)/open", body: [:], auth: auth)
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(http.statusCode, Self.message(data))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = obj["url"] as? String, let url = URL(string: urlStr),
              let issuer = obj["issuerToken"] as? String
        else { throw ProviderError.decoding("open response missing url/issuerToken") }
        return OpenedInstance(url: url, issuerToken: issuer)
    }

    // MARK: - Pure parsers (testable)

    static func parseAuthOutcome(_ data: Data) throws -> AuthOutcome {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("not JSON")
        }
        if let token = obj["accessToken"] as? String, !token.isEmpty {
            let memberships = (obj["memberships"] as? [[String: Any]] ?? []).map { m in
                Membership(
                    tenantId: m["tenantId"] as? String ?? "",
                    tenantName: m["tenantName"] as? String ?? "",
                    tenantSlug: m["tenantSlug"] as? String ?? "",
                    role: m["role"] as? String ?? "",
                    isRoot: m["isRoot"] as? Bool ?? false)
            }.filter { !$0.tenantId.isEmpty }
            return .authenticated(AuthSession(accessToken: token, memberships: memberships))
        }
        if (obj["mfaRequired"] as? Bool) == true, let mfa = obj["mfaToken"] as? String {
            return .mfaRequired(mfaToken: mfa)
        }
        throw ProviderError.decoding("no accessToken and no MFA challenge")
    }

    static func parseInstances(_ data: Data) -> [InstanceSummary] {
        let root = try? JSONSerialization.jsonObject(with: data)
        let arr: [[String: Any]]
        if let d = root as? [String: Any] { arr = d["instances"] as? [[String: Any]] ?? [] }
        else { arr = root as? [[String: Any]] ?? [] }
        return arr.compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            return InstanceSummary(
                id: id,
                name: (o["name"] as? String) ?? (o["nodeName"] as? String) ?? "Hearthloom",
                url: (o["url"] as? String).flatMap(URL.init(string:)),
                ready: (o["ready"] as? Bool) ?? (o["status"] as? String == "ready"),
                status: (o["status"] as? String) ?? "")
        }
    }

    // MARK: - HTTP

    private func get(path: String, auth: Auth?) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        apply(auth, to: &req)
        let (d, r) = try await HearthAPI.session.data(for: req)
        return (d, r as! HTTPURLResponse)
    }

    private func post(path: String, body: [String: Any], auth: Auth?) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !body.isEmpty { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        apply(auth, to: &req)
        let (d, r) = try await HearthAPI.session.data(for: req)
        return (d, r as! HTTPURLResponse)
    }

    private func apply(_ auth: Auth?, to req: inout URLRequest) {
        guard let auth else { return }
        req.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(auth.tenantId, forHTTPHeaderField: "X-Tenant-ID")
    }

    private static func message(_ data: Data) -> String {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            ?? "request failed"
    }
}
