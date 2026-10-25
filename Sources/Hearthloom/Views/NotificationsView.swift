import SwiftUI

/// The node's notification queue (hints, never private data). Pull-based list
/// using the `read`/`notify` scope. Phase 3 upgrades this to live SSE via
/// `/v1/bus/stream`.
struct NotificationsView: View {
    let connection: Connection

    @State private var items: [HearthAPI.HearthNotification] = []
    @State private var unread = 0
    @State private var loading = false
    @State private var error: String?
    @State private var loadedOnce = false
    @Environment(\.openURL) private var openURL

    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.red)
            }
            if items.isEmpty && !loading && error == nil {
                ContentUnavailableView("No notifications", systemImage: "bell.slash",
                                       description: Text("You're all caught up."))
            }
            ForEach(items) { note in
                row(note)
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if unread > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mark all read") { Task { await markAllRead() } }
                        .font(.footnote)
                }
            }
        }
        .overlay { if loading && items.isEmpty { ProgressView().tint(HearthTheme.accent) } }
        .refreshable { await load() }
        .task {
            guard !loadedOnce else { return }
            loadedOnce = true
            await load()
        }
        .tint(HearthTheme.accent)
    }

    @ViewBuilder
    private func row(_ note: HearthAPI.HearthNotification) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: note.severity))
                    .frame(width: 8, height: 8)
                    .opacity(note.isUnread ? 1 : 0.25)
                Text(note.title)
                    .font(.subheadline.weight(note.isUnread ? .semibold : .regular))
                Spacer()
                Text(note.origin).font(.caption2).foregroundStyle(.tertiary)
            }
            if !note.body.isEmpty {
                Text(note.body).font(.footnote).foregroundStyle(.secondary)
            }
            if let link = note.link, let url = resolvedLink(link) {
                Button(note.linkLabel ?? "Open") { openURL(url) }
                    .font(.caption).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if note.isUnread { Task { await markRead(note.id) } } }
    }

    private func color(for severity: String) -> Color {
        switch severity.lowercased() {
        case "error", "critical": return .red
        case "warn", "warning": return .orange
        case "success": return .green
        default: return HearthTheme.accent
        }
    }

    /// Node links may be relative (`/notes/…`) — resolve against the base URL.
    private func resolvedLink(_ link: String) -> URL? {
        if link.hasPrefix("http") { return URL(string: link) }
        return URL(string: link, relativeTo: connection.baseURL)?.absoluteURL
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let resp = try await api.notifications(pat: connection.deviceToken)
            items = resp.notifications
            unread = resp.unread
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func markRead(_ id: String) async {
        do {
            try await api.markNotificationRead(pat: connection.deviceToken, id: id)
            await load()
        } catch { /* best-effort; a reload will reconcile */ }
    }

    private func markAllRead() async {
        do {
            try await api.markAllNotificationsRead(pat: connection.deviceToken)
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
