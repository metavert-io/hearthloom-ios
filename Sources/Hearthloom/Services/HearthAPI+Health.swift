import Foundation

/// `POST /v1/ingest/health` — HealthKit batch ingest. Uses the `ingest` scope.
/// The node reuses its `apple_health` adapter aggregation; idempotent per HK
/// sample `uuid`.
extension HearthAPI {
    struct HealthIngestResult: Equatable {
        let accepted: Int
        let duplicates: Int
        let workoutsNew: Int
    }

    func ingestHealth(pat: String, actor: String, device: String,
                      samples: [HealthSampleRecord],
                      workouts: [HealthWorkoutRecord]) async throws -> HealthIngestResult {
        try await Observability.traced("ingest v1/ingest/health", operation: "http.ingest") {
            try await ingestHealthRequest(pat: pat, actor: actor, device: device,
                                          samples: samples, workouts: workouts)
        }
    }

    private func ingestHealthRequest(pat: String, actor: String, device: String,
                                     samples: [HealthSampleRecord],
                                     workouts: [HealthWorkoutRecord]) async throws -> HealthIngestResult {
        let body = HealthPayload.build(actor: actor, device: device,
                                       samples: samples, workouts: workouts)
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/ingest/health"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notReachable("no response") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized("The device token can't ingest health data.")
        }
        if http.statusCode == 404 {
            throw APIError.server(404, "This node doesn't support /v1/ingest/health yet.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError.server(http.statusCode, msg ?? "health ingest failed")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return HealthIngestResult(
            accepted: (obj["accepted"] as? Int) ?? 0,
            duplicates: (obj["duplicates"] as? Int) ?? 0,
            workoutsNew: (obj["workouts_new"] as? Int) ?? 0)
    }
}
