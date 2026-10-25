import Foundation

/// Wire records for device-only HealthKit ingest (Phase 1 / Track B). These are
/// plain, HealthKit-free structs so the payload builder is unit-testable without
/// a device. They mirror hearthloom's `apple_health` adapter `Sample`/`WorkoutRec`
/// (short metric name, value, unit, category, source) so the device stream and
/// the export.xml backfill UPSERT into the same `health_day` aggregation rather
/// than duplicating. See docs/node-api.md for the request body.

/// One HealthKit sample, normalized. `uuid` is the HK sample UUID — the
/// idempotency key (with `source:"apple-health"`) so re-sends are no-ops.
struct HealthSampleRecord: Codable, Equatable {
    let uuid: String
    /// Short metric, HK prefix stripped: `StepCount`, `HeartRate`, `SleepAnalysis`.
    let metric: String
    /// Numeric value for quantity samples; nil for pure category samples.
    let value: Double?
    /// Canonical unit string for the metric (`count`, `count/min`, `kcal`, `m`, `kg`).
    let unit: String?
    /// Category value for category samples (e.g. `AsleepDeep`), HK prefix stripped.
    let category: String?
    /// HK source name (`iPhone`, `Apple Watch`).
    let source: String
    let start: String   // RFC3339 UTC
    let end: String     // RFC3339 UTC
    let tzOffsetMinutes: Int
}

/// One HealthKit workout.
struct HealthWorkoutRecord: Codable, Equatable {
    let uuid: String
    let activity: String        // e.g. `Running`, `FunctionalStrengthTraining`
    let start: String
    let end: String
    let energyKcal: Double?
    let distanceM: Double?
    let source: String
    let tzOffsetMinutes: Int
}

/// Builds the `POST /v1/ingest/health` body. Pure + deterministic.
enum HealthPayload {
    static func build(actor: String, device: String,
                      samples: [HealthSampleRecord],
                      workouts: [HealthWorkoutRecord]) -> [String: Any] {
        [
            "actor": actor,
            "source": "apple-health",
            "device": device,
            "samples": samples.map(sampleDict),
            "workouts": workouts.map(workoutDict),
        ]
    }

    private static func sampleDict(_ s: HealthSampleRecord) -> [String: Any] {
        var d: [String: Any] = [
            "uuid": s.uuid,
            "metric": s.metric,
            "source": s.source,
            "start": s.start,
            "end": s.end,
            "tz_offset_minutes": s.tzOffsetMinutes,
        ]
        if let v = s.value { d["value"] = v }
        if let u = s.unit { d["unit"] = u }
        if let c = s.category { d["category"] = c }
        return d
    }

    private static func workoutDict(_ w: HealthWorkoutRecord) -> [String: Any] {
        var d: [String: Any] = [
            "uuid": w.uuid,
            "activity": w.activity,
            "start": w.start,
            "end": w.end,
            "source": w.source,
            "tz_offset_minutes": w.tzOffsetMinutes,
        ]
        if let e = w.energyKcal { d["energy_kcal"] = e }
        if let dist = w.distanceM { d["distance_m"] = dist }
        return d
    }
}
