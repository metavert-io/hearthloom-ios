import Foundation
import HealthKit

/// Device-only HealthKit ingest (Phase 1 / Track B). Streams incremental samples
/// to the node via `HKAnchoredObjectQuery` + persisted anchors, batching by HK
/// sample `UUID` for idempotency. Live samples update the node's derived
/// `health_index` sidecar immediately; the append-only `health_day` EPISODE is
/// minted once per day by a server-side finalize pass — never rewritten intra-day
/// (docs/node-api.md, "Device ingest").
///
/// Streams to the node's `POST /v1/ingest/health`;
/// `HealthIngestConfig.streamingEnabled` pauses uploads.
@MainActor
final class HealthKitIngest: ObservableObject {
    enum AuthState: Equatable { case unknown, unavailable, denied, authorized }

    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var lastError: String?
    @Published private(set) var lastBatchCount: Int = 0
    /// Persisted across app launches / view reopens (the session count resets).
    @Published private(set) var lastSyncedAt: Date? =
        UserDefaults.standard.object(forKey: "health.lastSyncedAt") as? Date

    private let store = HKHealthStore()
    private let anchors: HealthAnchorStore
    private let connection: Connection
    private var runningQueries: [HKQuery] = []

    init(connection: Connection, anchors: HealthAnchorStore = HealthAnchorStore()) {
        self.connection = connection
        self.anchors = anchors
        if !HKHealthStore.isHealthDataAvailable() { authState = .unavailable }
    }

    // MARK: - Types we read

    /// Canonical unit per quantity metric — matches the units the export.xml
    /// backfill records, so both paths aggregate consistently.
    nonisolated(unsafe) static let quantityUnits: [HKQuantityTypeIdentifier: HKUnit] = [
        .stepCount: .count(),
        .distanceWalkingRunning: .meter(),
        .activeEnergyBurned: .kilocalorie(),
        .basalEnergyBurned: .kilocalorie(),
        .appleExerciseTime: .minute(),
        .heartRate: HKUnit.count().unitDivided(by: .minute()),
        .restingHeartRate: HKUnit.count().unitDivided(by: .minute()),
        .heartRateVariabilitySDNN: .secondUnit(with: .milli),
        .respiratoryRate: HKUnit.count().unitDivided(by: .minute()),
        .oxygenSaturation: .percent(),
        .bodyMass: .gramUnit(with: .kilo),
    ]

    nonisolated static let categoryIdentifiers: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis, .mindfulSession,
    ]

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for id in Self.quantityUnits.keys {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        for id in Self.categoryIdentifiers {
            if let t = HKObjectType.categoryType(forIdentifier: id) { types.insert(t) }
        }
        types.insert(HKObjectType.workoutType())
        return types
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { authState = .unavailable; return }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            // HealthKit never reveals read-grant per privacy; treat request
            // completion as "proceed" and let queries return what's permitted.
            authState = .authorized
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        } catch {
            authState = .denied
            lastError = error.localizedDescription
        }
    }

    // MARK: - Streaming

    /// Start anchored queries for every type, resuming from persisted anchors and
    /// subscribing to background delivery. Sends flow when
    /// `HealthIngestConfig.streamingEnabled` (the pause switch) is on.
    func start() {
        guard authState == .authorized else { return }
        stop()
        for type in readTypes {
            guard let sampleType = type as? HKSampleType else { continue }
            let key = sampleType.identifier
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: nil,
                anchor: anchors.anchor(for: key),
                limit: HKObjectQueryNoLimit
            ) { [weak self] _, samples, _, newAnchor, error in
                self?.handle(samples: samples, newAnchor: newAnchor, key: key, error: error)
            }
            query.updateHandler = { [weak self] _, samples, _, newAnchor, error in
                self?.handle(samples: samples, newAnchor: newAnchor, key: key, error: error)
            }
            store.execute(query)
            runningQueries.append(query)
            store.enableBackgroundDelivery(for: sampleType, frequency: .hourly) { _, _ in }
        }
    }

    func stop() {
        runningQueries.forEach { store.stop($0) }
        runningQueries.removeAll()
    }

    /// Clear persisted anchors and re-run from scratch — a full re-backfill.
    /// Dupe-safe: the node dedups every sample on its HK `UUID`.
    func forceResync() {
        guard authState == .authorized else { return }
        stop()
        let keys = readTypes.compactMap { ($0 as? HKSampleType)?.identifier }
        anchors.clearAll(keys: keys)
        lastBatchCount = 0
        start()
    }

    private nonisolated func handle(samples: [HKSample]?, newAnchor: HKQueryAnchor?,
                                    key: String, error: Error?) {
        let records = (samples ?? []).compactMap(Self.record(from:))
        let workouts = (samples ?? []).compactMap { $0 as? HKWorkout }.map(Self.record(fromWorkout:))
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error { self.lastError = error.localizedDescription }
            if records.isEmpty && workouts.isEmpty {
                if let a = newAnchor { self.anchors.setAnchor(a, for: key) }
                return
            }
            do {
                if HealthIngestConfig.streamingEnabled {
                    // The first anchored run returns a type's ENTIRE history in
                    // one callback — potentially 100k+ samples. Chunk it so no
                    // single POST is huge; the anchor advances only after every
                    // chunk succeeds, so a mid-sync failure safely retries.
                    let api = HearthAPI(baseURL: self.connection.baseURL)
                    let actor = "adapter:ios-\(Self.deviceSlug)"
                    var pendingWorkouts = workouts
                    let pat = self.connection.deviceToken
                    if records.isEmpty {
                        let w = pendingWorkouts
                        _ = try await IngestGate.shared.run {
                            try await api.ingestHealth(pat: pat, actor: actor,
                                device: Self.deviceName, samples: [], workouts: w)
                        }
                        self.lastBatchCount += w.count
                    } else {
                        var i = 0
                        while i < records.count {
                            let slice = Array(records[i..<min(i + Self.chunkSize, records.count)])
                            let w = pendingWorkouts; pendingWorkouts = []   // workouts ride the first chunk
                            _ = try await IngestGate.shared.run {
                                try await api.ingestHealth(pat: pat, actor: actor,
                                    device: Self.deviceName, samples: slice, workouts: w)
                            }
                            self.lastBatchCount += slice.count + w.count
                            i += Self.chunkSize
                        }
                    }
                    let now = Date()
                    self.lastSyncedAt = now
                    UserDefaults.standard.set(now, forKey: "health.lastSyncedAt")
                } else {
                    self.lastBatchCount += records.count + workouts.count
                }
                // Only advance the anchor once ALL chunks are durably handled.
                if let a = newAnchor { self.anchors.setAnchor(a, for: key) }
            } catch {
                self.lastError = error.localizedDescription
                // Leave the anchor unadvanced so the whole delta retries next run.
            }
        }
    }

    /// Max HealthKit samples per `/v1/ingest/health` POST.
    private static let chunkSize = 500

    /// Set once the user connects Apple Health; drives app-level auto-start.
    static let enabledKey = "health.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    // MARK: - HK → record mapping (pure helpers, testable)

    /// Strip the HK type prefix to the short metric name used by the adapter.
    nonisolated static func shortMetric(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
    }

    /// Human-readable sleep stage from the raw HKCategoryValueSleepAnalysis.
    nonisolated static func sleepStageName(_ raw: Int) -> String {
        switch raw {
        case HKCategoryValueSleepAnalysis.inBed.rawValue: return "InBed"
        case HKCategoryValueSleepAnalysis.awake.rawValue: return "Awake"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: return "AsleepCore"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: return "AsleepDeep"
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: return "AsleepREM"
        default: return "AsleepUnspecified"
        }
    }

    nonisolated static func record(from sample: HKSample) -> HealthSampleRecord? {
        let tz = TimeZone.current.secondsFromGMT() / 60
        let start = HearthAPI.rfc3339(sample.startDate)
        let end = HearthAPI.rfc3339(sample.endDate)
        let source = sample.sourceRevision.source.name

        if let q = sample as? HKQuantitySample {
            let id = HKQuantityTypeIdentifier(rawValue: q.quantityType.identifier)
            guard let unit = quantityUnits[id] else { return nil }
            return HealthSampleRecord(
                uuid: q.uuid.uuidString, metric: shortMetric(q.quantityType.identifier),
                value: q.quantity.doubleValue(for: unit), unit: unit.unitString,
                category: nil, source: source, start: start, end: end, tzOffsetMinutes: tz)
        }
        if let c = sample as? HKCategorySample {
            let metric = shortMetric(c.categoryType.identifier)
            let category = metric == "SleepAnalysis" ? sleepStageName(c.value) : nil
            return HealthSampleRecord(
                uuid: c.uuid.uuidString, metric: metric, value: nil, unit: nil,
                category: category, source: source, start: start, end: end, tzOffsetMinutes: tz)
        }
        return nil
    }

    nonisolated static func record(fromWorkout w: HKWorkout) -> HealthWorkoutRecord {
        let tz = TimeZone.current.secondsFromGMT() / 60
        let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())
            ?? w.totalEnergyBurned?.doubleValue(for: .kilocalorie())
        let distance = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter())
            ?? w.totalDistance?.doubleValue(for: .meter())
        return HealthWorkoutRecord(
            uuid: w.uuid.uuidString,
            activity: workoutActivityName(w.workoutActivityType),
            start: HearthAPI.rfc3339(w.startDate), end: HearthAPI.rfc3339(w.endDate),
            energyKcal: energy, distanceM: distance,
            source: w.sourceRevision.source.name, tzOffsetMinutes: tz)
    }

    /// Readable name for a workout type (server stores this string; matches the
    /// export adapter's activity names). Unmapped types fall back to the rawValue.
    nonisolated static func workoutActivityName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .dance, .cardioDance: return "Dance"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing, .stairs: return "StairClimbing"
        case .traditionalStrengthTraining: return "StrengthTraining"
        case .functionalStrengthTraining: return "FunctionalStrengthTraining"
        case .highIntensityIntervalTraining: return "HIIT"
        case .coreTraining: return "CoreTraining"
        case .flexibility: return "Flexibility"
        case .cooldown: return "Cooldown"
        case .mixedCardio: return "MixedCardio"
        default: return "Workout-\(t.rawValue)"
        }
    }

    // MARK: - Device identity

    static var deviceName: String { "iPhone" }
    static var deviceSlug: String { "healthkit" }
}

/// Feature flag for Track B health uploads. On: live samples stream to the
/// node's `POST /v1/ingest/health`. Turn it off only to pause uploads.
enum HealthIngestConfig {
    static let streamingEnabled = true
}
