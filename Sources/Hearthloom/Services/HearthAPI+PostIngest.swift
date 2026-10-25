import Foundation

/// Generic device-ingest POST reused by the newer adapters (contacts, calendar,
/// …). Same contract as health/photos: Bearer PAT, `{actor,source,device,items}`
/// body, `{accepted,duplicates}` reply; a 404 means the node predates that
/// endpoint.
extension HearthAPI {
    struct IngestCount: Equatable { let accepted: Int; let duplicates: Int }
    struct EndpointUnavailable: Error {}

    func postIngest(path: String, pat: String, body: [String: Any]) async throws -> IngestCount {
        try await Observability.traced("ingest \(path)", operation: "http.ingest") {
            try await postIngestRequest(path: path, pat: pat, body: body)
        }
    }

    private func postIngestRequest(path: String, pat: String, body: [String: Any]) async throws -> IngestCount {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notReachable("no response") }
        if http.statusCode == 404 { throw EndpointUnavailable() }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized("The device token can't ingest to this node.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError.server(http.statusCode, msg ?? "ingest failed")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return IngestCount(accepted: (obj["accepted"] as? Int) ?? 0,
                           duplicates: (obj["duplicates"] as? Int) ?? 0)
    }
}
