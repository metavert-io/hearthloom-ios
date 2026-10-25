import Foundation

/// Node notifications (`notify`/`read` scope — already on the device PAT):
/// `GET /v1/notifications`, `POST /v1/notifications/read-all` and
/// `POST /v1/notifications/{id}/read`. Rows mirror the node's `NotificationRow`
/// (hearthloom's `crates/hearthloom-core/src/store/notifications.rs`). These
/// are hints, never data — private content never rides the queue.
extension HearthAPI {
    struct HearthNotification: Identifiable, Equatable {
        let id: String
        let ts: String
        let severity: String
        let origin: String
        let title: String
        let body: String
        let link: String?
        let linkLabel: String?
        let readAt: String?

        var isUnread: Bool { readAt == nil }

        init?(_ dict: [String: Any]) {
            guard let id = dict["id"] as? String else { return nil }
            self.id = id
            self.ts = dict["ts"] as? String ?? ""
            self.severity = dict["severity"] as? String ?? "info"
            self.origin = dict["origin"] as? String ?? ""
            self.title = dict["title"] as? String ?? ""
            self.body = dict["body"] as? String ?? ""
            self.link = dict["link"] as? String
            self.linkLabel = dict["link_label"] as? String
            self.readAt = dict["read_at"] as? String
        }
    }

    struct NotificationsResponse: Equatable {
        let notifications: [HearthNotification]
        let unread: Int
    }

    /// `GET /v1/notifications` → `{notifications, unread, killswitch}`.
    func notifications(pat: String) async throws -> NotificationsResponse {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/notifications"))
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notReachable("no response") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized("The device token was rejected.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(http.statusCode, "notifications fetch failed")
        }
        return Self.parseNotifications(data)
    }

    /// Pure parse (testable without a network).
    static func parseNotifications(_ data: Data) -> NotificationsResponse {
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let rows = (obj["notifications"] as? [[String: Any]]) ?? []
        let items = rows.compactMap(HearthNotification.init)
        let unread = (obj["unread"] as? Int) ?? items.filter(\.isUnread).count
        return NotificationsResponse(notifications: items, unread: unread)
    }

    /// `POST /v1/notifications/{id}/read` (no body).
    func markNotificationRead(pat: String, id: String) async throws {
        try await postNoBody(path: "v1/notifications/\(id)/read", pat: pat)
    }

    /// `POST /v1/notifications/read-all` (no body).
    func markAllNotificationsRead(pat: String) async throws {
        try await postNoBody(path: "v1/notifications/read-all", pat: pat)
    }

    private func postNoBody(path: String, pat: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (_, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notReachable("no response") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw APIError.unauthorized("The device token was rejected.")
            }
            throw APIError.server(http.statusCode, "request failed")
        }
    }
}
