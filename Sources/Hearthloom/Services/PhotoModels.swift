import Foundation

/// Wire records for photo-location ingest (Track B / Phase 3). Only location +
/// minimal metadata leaves the device — never the image itself. HealthKit-style:
/// pure structs so the payload builder is unit-testable without PhotoKit.
///
/// `key` is the cross-device dedup identity: `<unix-capture-seconds>|<filename>`.
/// PHAsset.localIdentifier is NOT stable across the Mac Photos library and the
/// phone, but capture-time + original filename are visible to BOTH the computer
/// `photos.rs` scan and this adapter — so keying on them lets the two sources
/// converge (union), not duplicate. The server dedups location points on `key`
/// and mints the same per-day `photos#YYYY-MM-DD` episode either path produces.
struct PhotoLocationRecord: Codable, Equatable {
    let key: String
    let filename: String
    let takenAt: String        // RFC3339 UTC
    let tzOffsetMinutes: Int
    let lat: Double
    let lon: Double
}

enum PhotoPayload {
    /// Stable cross-device key: whole-second capture time + original filename.
    static func key(takenAt: Date, filename: String) -> String {
        "\(Int(takenAt.timeIntervalSince1970))|\(filename)"
    }

    /// Build the `POST /v1/ingest/photos` body. Pure + deterministic.
    static func build(actor: String, device: String,
                      photos: [PhotoLocationRecord]) -> [String: Any] {
        [
            "actor": actor,
            "source": "photos",
            "device": device,
            "photos": photos.map { p in
                [
                    "key": p.key,
                    "filename": p.filename,
                    "taken_at": p.takenAt,
                    "tz_offset_minutes": p.tzOffsetMinutes,
                    "lat": p.lat,
                    "lon": p.lon,
                ] as [String: Any]
            },
        ]
    }
}
