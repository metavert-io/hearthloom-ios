import Foundation
import MediaPlayer

/// Media/taste adapter (Tier 2) → `POST /v1/ingest/media`. Sends items that have
/// actually been played (last-played date + play count) from the Music library.
/// Idempotent per item by persistentID; `MediaIngestConfig.streamingEnabled`
/// pauses uploads.
struct MediaRecord: Codable, Equatable {
    let key: String, kind: String, title: String
    let artist: String?, show: String?, album: String?
    let playedAt: String
    let durationS: Int?
}

enum MediaPayload {
    static func build(actor: String, device: String, items: [MediaRecord]) -> [String: Any] {
        ["actor": actor, "source": "ios-media", "device": device,
         "items": items.map { m -> [String: Any] in
            var d: [String: Any] = ["key": m.key, "kind": m.kind, "title": m.title,
                                    "played_at": m.playedAt]
            if let v = m.artist { d["artist"] = v }
            if let v = m.show { d["show"] = v }
            if let v = m.album { d["album"] = v }
            if let v = m.durationS { d["duration_s"] = v }
            return d
        }]
    }
}

enum MediaIngestConfig { static let streamingEnabled = true }

@MainActor
final class MediaIngest: DeviceAdapter {
    @Published private(set) var syncedCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false
    @Published private(set) var lastSyncedAt: Date? =
        UserDefaults.standard.object(forKey: "media.lastSyncedAt") as? Date

    private let connection: Connection
    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }
    init(connection: Connection) { self.connection = connection }

    static let enabledKey = "media.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    var connected: Bool { MPMediaLibrary.authorizationStatus() == .authorized }
    var statusText: String { connected ? "Connected" : "Not connected" }
    var pendingNote: String? { MediaIngestConfig.streamingEnabled ? nil
        : "Uploading is pending the node’s /v1/ingest/media endpoint." }

    func connect() async {
        busy = true; lastError = nil          // spinner during the OS prompt + first heavy scan
        let status = await MPMediaLibrary.requestAuthorization()
        busy = false
        if status == .authorized {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            await scan()
        } else { lastError = "Music library access denied." }
    }

    func forceResync() async { syncedCount = 0; await scan() }

    func scan() async {
        guard connected else { return }
        busy = true; lastError = nil; defer { busy = false }
        // Iterating the whole Music/Podcast library is heavy — do it off the main
        // thread or a large library blocks the UI and trips the watchdog (the
        // "Connect does nothing then the app dies" flakiness). Mirrors ContactsIngest.
        let records = await Task.detached(priority: .utility) { Self.collect() }.value
        for chunk in stride(from: 0, to: records.count, by: 200).map({ Array(records[$0..<min($0+200, records.count)]) }) {
            do {
                if MediaIngestConfig.streamingEnabled {
                    let api = self.api, pat = connection.deviceToken
                    let body = MediaPayload.build(actor: "adapter:ios-media", device: "iPhone", items: chunk)
                    _ = try await IngestGate.shared.run { try await api.postIngest(path: "v1/ingest/media", pat: pat, body: body) }
                }
                syncedCount += chunk.count
                let now = Date(); lastSyncedAt = now
                UserDefaults.standard.set(now, forKey: "media.lastSyncedAt")
            } catch { lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; return }
        }
    }

    nonisolated static func collect() -> [MediaRecord] {
        var out: [MediaRecord] = []
        for (query, kind, isPodcast) in [(MPMediaQuery.songs(), "song", false),
                                         (MPMediaQuery.podcasts(), "podcast", true)] {
            for item in (query.items ?? []) where item.lastPlayedDate != nil {
                out.append(MediaRecord(
                    key: "\(item.persistentID)",
                    kind: kind,
                    title: item.title ?? "(untitled)",
                    artist: isPodcast ? nil : item.artist,
                    show: isPodcast ? (item.podcastTitle ?? item.albumTitle) : nil,
                    album: isPodcast ? nil : item.albumTitle,
                    playedAt: HearthAPI.rfc3339(item.lastPlayedDate!),
                    durationS: item.playbackDuration > 0 ? Int(item.playbackDuration) : nil))
            }
        }
        return out
    }
}
