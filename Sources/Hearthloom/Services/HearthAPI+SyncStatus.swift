import Foundation

/// Device sync audit — reads the brain's own record of what THIS phone sent, so
/// the app can verify ingestion top-to-bottom. Backed by the node's
/// `GET /v1/ingest/status` (+ paged `/v1/ingest/recent`); a node that predates
/// them answers 404, which surfaces as `SyncStatusUnavailable`.
extension HearthAPI {
    struct IngestSummary: Identifiable, Equatable {
        let source: String        // "apple-health" | "photos"
        let actor: String         // "adapter:ios-…"
        let count: Int            // raw samples / photo points landed
        let lastIngestAt: String? // when the node last accepted a batch
        let daysCovered: Int
        var id: String { source }
    }

    struct IngestLogEntry: Identifiable, Equatable {
        let ts: String
        let source: String
        let kind: String
        let count: Int
        let ref: String
        var id: String { ts + ref }
    }

    struct SyncStatusUnavailable: Error {}   // 404 → this node predates the endpoint

    /// `GET /v1/ingest/status` → per-source summary of raw device ingestion.
    func ingestStatus(pat: String) async throws -> [IngestSummary] {
        let data = try await getJSON(path: "v1/ingest/status", pat: pat)
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["sources"] as? [[String: Any]] ?? []
        return rows.map { o in
            IngestSummary(
                source: o["source"] as? String ?? "?",
                actor: o["actor"] as? String ?? "",
                count: (o["count"] as? Int) ?? (o["samples"] as? Int) ?? (o["points"] as? Int) ?? 0,
                lastIngestAt: o["last_ingest_at"] as? String,
                daysCovered: o["days_covered"] as? Int ?? 0)
        }
    }

    /// `GET /v1/ingest/recent?limit=&offset=` → paged audit trail of batches.
    func ingestRecent(pat: String, offset: Int, limit: Int) async throws -> [IngestLogEntry] {
        let data = try await getJSON(path: "v1/ingest/recent", pat: pat,
                                     query: [("offset", "\(offset)"), ("limit", "\(limit)")])
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return rows.map { o in
            IngestLogEntry(
                ts: o["ts"] as? String ?? o["at"] as? String ?? "",
                source: o["source"] as? String ?? "?",
                kind: o["kind"] as? String ?? "",
                count: o["count"] as? Int ?? 0,
                ref: o["ref"] as? String ?? o["source_ref"] as? String ?? "")
        }
    }

    private func getJSON(path: String, pat: String, query: [(String, String)] = []) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notReachable("no response") }
        if http.statusCode == 404 { throw SyncStatusUnavailable() }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized("token rejected") }
        guard (200..<300).contains(http.statusCode) else { throw APIError.server(http.statusCode, "sync status failed") }
        return data
    }
}
