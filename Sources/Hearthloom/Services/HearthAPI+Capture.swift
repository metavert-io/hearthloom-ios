import Foundation

/// One-tap capture → `POST /v1/ingest/capture`. Same shape as the other ingest
/// clients (Bearer token, JSON body, typed errors, `Observability.traced`) but
/// its own method: the reply is `{kind, id, duplicate}`, not `postIngest`'s
/// `{accepted, duplicates}`. The endpoint is write-only — the reply carries the
/// new id and nothing else.
enum CapturePayload {
    /// `kind` is omitted so the server's `auto` files it; `device` is the same
    /// label the other adapters send.
    static func build(item: CaptureItem, device: String = "iPhone") -> [String: Any] {
        var o: [String: Any] = ["text": item.text, "captured_at": item.capturedAt,
                                "client_ref": item.clientRef, "device": device]
        if let lat = item.lat, let lon = item.lon { o["lat"] = lat; o["lon"] = lon }
        return o
    }
}

extension HearthAPI {
    struct CaptureReply: Equatable {
        let kind: String
        let id: String
        let duplicate: Bool
    }

    /// What the queue needs to know about a failed upload: drop it, or keep it
    /// and why.
    enum CaptureError: LocalizedError, Equatable {
        case rejected(String)        // 400: empty or too long — never retry
        case unauthorized            // 401/403: credential rejected — keep, reconnect
        case endpointUnavailable     // 404: this node doesn't have capture yet — keep
        case rateLimited             // 429 — keep, retry later
        case transient(String)       // 5xx / network — keep, retry with backoff

        var errorDescription: String? {
            switch self {
            case .rejected(let m): return "The node refused a capture: \(m)"
            case .unauthorized: return "The capture key was rejected by the node."
            case .endpointUnavailable: return "This node doesn’t support capture yet. Captures stay queued on this iPhone."
            case .rateLimited: return "The node’s capture limit was reached. Captures will upload later."
            case .transient(let m): return "Couldn’t upload: \(m)"
            }
        }

        /// Map a non-200 status to its queue outcome.
        static func from(status: Int, message: String?) -> CaptureError {
            switch status {
            case 400: return .rejected(message ?? "bad request")
            case 401, 403: return .unauthorized
            case 404: return .endpointUnavailable
            case 429: return .rateLimited
            default: return .transient(message ?? "server error \(status)")
            }
        }
    }

    func captureRequest(token: String, item: CaptureItem) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/ingest/capture"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: CapturePayload.build(item: item))
        req.timeoutInterval = 20
        return req
    }

    /// `token` is the capture-only key, or the device token (its `ingest` scope
    /// is also accepted). Throws `CaptureError` only.
    func postCapture(token: String, item: CaptureItem) async throws -> CaptureReply {
        try await Observability.traced("ingest v1/ingest/capture", operation: "http.ingest") {
            let req = try captureRequest(token: token, item: item)
            let data: Data, resp: URLResponse
            do {
                (data, resp) = try await Self.session.data(for: req)
            } catch {
                throw CaptureError.transient(error.localizedDescription)
            }
            guard let http = resp as? HTTPURLResponse else { throw CaptureError.transient("no response") }
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard http.statusCode == 200 else {
                throw CaptureError.from(status: http.statusCode, message: obj["error"] as? String)
            }
            return CaptureReply(kind: (obj["kind"] as? String) ?? "note",
                                id: (obj["id"] as? String) ?? "",
                                duplicate: (obj["duplicate"] as? Bool) ?? false)
        }
    }

    /// A scoped key takes grants and NO scopes. `own_device` says this phone is
    /// one of the owner's own devices, so the node records its captures as the
    /// owner's own words (fully trusted) instead of an agent's. It widens
    /// nothing the key can reach; a node that predates it ignores it.
    static func captureKeyBody(deviceName: String) -> [String: Any] {
        ["actor": "adapter:ios-capture",
         "name": "iphone-capture-\(sanitize(deviceName))",
         "grants": ["capture": true, "own_device": true]]
    }

    /// Does a `/v1/keys` reply describe a capture-ONLY key? Checked before the
    /// secret is stored behind a locked phone: anything broader is refused.
    /// Grants that widen nothing (`own_device`, rate caps) are fine.
    static func isCaptureOnlyKey(_ reply: [String: Any]) -> Bool {
        guard let key = reply["key"] as? [String: Any],
              let grants = key["grants"] as? [String: Any],
              grants["capture"] as? Bool == true,
              (key["scopes"] as? [String] ?? []).isEmpty else { return false }
        let none: (String) -> Bool = { (grants[$0] as? String ?? "none") == "none" }
        return none("tasks") && none("notes") && none("memory") && grants["ask"] as? Bool != true
    }

    /// Mint the capture-only scoped key with the device token (`POST /v1/keys`).
    /// A node without scoped keys (≤ 0.5.60) answers 422 (`scopes` missing) or
    /// 404 → `EndpointUnavailable`.
    func mintCaptureKey(pat: String, deviceName: String) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/keys"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.captureKeyBody(deviceName: deviceName))
        req.timeoutInterval = 20
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notReachable("no response") }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if http.statusCode == 404 || http.statusCode == 422 { throw EndpointUnavailable() }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized("The device token can’t create a capture key on this node.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, (obj["error"] as? String) ?? "key mint failed")
        }
        guard let secret = obj["secret"] as? String, !secret.isEmpty else {
            throw APIError.decoding("no secret in key-mint response")
        }
        guard Self.isCaptureOnlyKey(obj) else {
            throw APIError.decoding("the node returned a key that isn’t capture-only; not storing it")
        }
        return secret
    }
}
