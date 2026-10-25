import Foundation

/// `POST /v1/ingest/photos` — photo-location ingest (nodes 0.5.51 and later;
/// body in docs/node-api.md). Uses the `ingest` scope. The server
/// dedups per-photo location points on `key` and mints/refreshes the per-day
/// `photos#YYYY-MM-DD` episode from the union with the computer `photos.rs` scan.
extension HearthAPI {
    struct PhotoIngestResult: Equatable {
        let accepted: Int
        let duplicates: Int
    }

    func ingestPhotos(pat: String, actor: String, device: String,
                      photos: [PhotoLocationRecord]) async throws -> PhotoIngestResult {
        try await Observability.traced("ingest v1/ingest/photos", operation: "http.ingest") {
            try await ingestPhotosRequest(pat: pat, actor: actor, device: device, photos: photos)
        }
    }

    private func ingestPhotosRequest(pat: String, actor: String, device: String,
                                     photos: [PhotoLocationRecord]) async throws -> PhotoIngestResult {
        let body = PhotoPayload.build(actor: actor, device: device, photos: photos)
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/ingest/photos"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notReachable("no response") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized("The device token can't ingest photos.")
        }
        if http.statusCode == 404 {
            throw APIError.server(404, "This node doesn't support /v1/ingest/photos yet.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError.server(http.statusCode, msg ?? "photo ingest failed")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return PhotoIngestResult(
            accepted: (obj["accepted"] as? Int) ?? 0,
            duplicates: (obj["duplicates"] as? Int) ?? 0)
    }
}
