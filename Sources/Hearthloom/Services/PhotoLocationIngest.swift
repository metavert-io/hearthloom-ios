import Foundation
import Photos

/// Device-only photo-LOCATION ingest (Track B / Phase 3). Reads `PHAsset`
/// geotags (never the images) and streams them to the node, which reconciles
/// them with the computer `photos.rs` scan by the shared `(capture-time,
/// filename)` key. Incremental via a persisted "last capture scanned" marker —
/// the device owns "what haven't I sent," same model as HealthKit anchors.
///
/// Uploading is live (`PhotoIngestConfig.streamingEnabled`); the node's
/// `POST /v1/ingest/photos` shipped in 0.5.51.
@MainActor
final class PhotoLocationIngest: ObservableObject {
    enum AuthState: Equatable { case unknown, denied, limited, authorized }

    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var scannedCount = 0   // photos examined during enumeration
    @Published private(set) var totalToSync = 0    // geotagged records found this scan
    @Published private(set) var syncedCount = 0    // records confirmed sent
    @Published private(set) var lastError: String?
    @Published private(set) var scanning = false
    @Published private(set) var lastSyncedAt: Date? =
        UserDefaults.standard.object(forKey: "photos.lastSyncedAt") as? Date

    private let connection: Connection
    private let markerKey = "photos.lastScannedEpoch"
    private var api: HearthAPI { HearthAPI(baseURL: connection.baseURL) }

    init(connection: Connection) {
        self.connection = connection
        apply(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        apply(status)
        if authState == .authorized || authState == .limited {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
    }

    static let enabledKey = "photos.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private func apply(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized: authState = .authorized
        case .limited: authState = .limited
        case .denied, .restricted: authState = .denied
        default: authState = .unknown
        }
    }

    // MARK: - Incremental scan

    /// Fetch geotagged photos newer than the marker, in capture order, and send
    /// them chunked. Advances the marker only after each chunk succeeds.
    func scan() async {
        guard authState == .authorized || authState == .limited else { return }
        scanning = true; lastError = nil
        defer { scanning = false }

        scannedCount = 0; totalToSync = 0
        let since = UserDefaults.standard.double(forKey: markerKey)   // 0 = full backfill
        // Enumerating the whole library (+ per-asset resource lookups) is heavy —
        // run it OFF the main actor so it never hangs the UI or trips the watchdog.
        // Report the running examined count so the UI shows life.
        let pending = await Task.detached(priority: .utility) { [weak self] in
            Self.collect(since: since) { examined in
                Task { @MainActor in self?.scannedCount = examined }
            }
        }.value

        totalToSync = pending.reduce(0) { $0 + $1.records.count }
        for (records, marker) in pending {
            do {
                if PhotoIngestConfig.streamingEnabled {
                    let pat = connection.deviceToken
                    let api = self.api
                    _ = try await IngestGate.shared.run {
                        try await api.ingestPhotos(pat: pat, actor: "adapter:ios-photos",
                                                   device: "iPhone", photos: records)
                    }
                }
                syncedCount += records.count
                UserDefaults.standard.set(marker, forKey: markerKey)   // advance only on success
                let now = Date()
                lastSyncedAt = now
                UserDefaults.standard.set(now, forKey: "photos.lastSyncedAt")
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return   // leave the marker; retry the rest next scan
            }
        }
    }

    /// Heavy PhotoKit enumeration — pure, off-actor. Returns Sendable value
    /// types so it's safe to hop back to the main actor with the result.
    nonisolated private static func collect(since: Double,
                                            progress: @escaping @Sendable (Int) -> Void)
        -> [(records: [PhotoLocationRecord], marker: Double)] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        if since > 0 {
            options.predicate = NSPredicate(format: "creationDate > %@",
                                            Date(timeIntervalSince1970: since) as NSDate)
        }
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        var batch: [PhotoLocationRecord] = []
        var newestEpoch = since
        var pending: [(records: [PhotoLocationRecord], marker: Double)] = []

        assets.enumerateObjects { asset, idx, _ in
            if idx % 200 == 0 { progress(idx + 1) }
            guard let loc = asset.location, let taken = asset.creationDate else { return }
            let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename
                ?? asset.localIdentifier
            let rec = PhotoLocationRecord(
                key: PhotoPayload.key(takenAt: taken, filename: filename),
                filename: filename,
                takenAt: HearthAPI.rfc3339(taken),
                tzOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,
                lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            batch.append(rec)
            newestEpoch = max(newestEpoch, taken.timeIntervalSince1970)
            if batch.count >= chunkSize {
                pending.append((batch, newestEpoch)); batch = []
            }
        }
        if !batch.isEmpty { pending.append((batch, newestEpoch)) }
        progress(assets.count)
        return pending
    }

    /// Reset the scan marker and re-scan the whole library — a full re-backfill.
    /// Dupe-safe: the node dedups every photo on its (capture-time, filename) key.
    func forceResync() async {
        UserDefaults.standard.removeObject(forKey: markerKey)
        syncedCount = 0
        await scan()
    }

    private static let chunkSize = 500
}

/// Track B photo flag. The node's `POST /v1/ingest/photos` shipped in 0.5.51
/// (v47 photo-point union), so geotags now stream. Flip off only to pause uploads.
enum PhotoIngestConfig {
    static let streamingEnabled = true
}
