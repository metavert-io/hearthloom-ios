import XCTest
@testable import Hearthloom

final class HealthTests: XCTestCase {

    // MARK: - Metric name mapping

    func testShortMetricStripsPrefixes() {
        XCTAssertEqual(HealthKitIngest.shortMetric("HKQuantityTypeIdentifierStepCount"), "StepCount")
        XCTAssertEqual(HealthKitIngest.shortMetric("HKCategoryTypeIdentifierSleepAnalysis"), "SleepAnalysis")
        XCTAssertEqual(HealthKitIngest.shortMetric("HeartRate"), "HeartRate")
    }

    func testSleepStageNames() {
        // Raw values are stable HKCategoryValueSleepAnalysis cases.
        XCTAssertEqual(HealthKitIngest.sleepStageName(0), "InBed")
        XCTAssertFalse(HealthKitIngest.sleepStageName(999).isEmpty)
    }

    // MARK: - Payload builder

    private func sample(_ metric: String, value: Double?, category: String? = nil) -> HealthSampleRecord {
        HealthSampleRecord(uuid: "u-\(metric)", metric: metric, value: value, unit: value == nil ? nil : "count",
                           category: category, source: "iPhone",
                           start: "2026-07-24T08:00:00Z", end: "2026-07-24T08:05:00Z",
                           tzOffsetMinutes: -240)
    }

    func testPayloadTopLevel() {
        let body = HealthPayload.build(actor: "adapter:ios-healthkit", device: "iPhone",
                                       samples: [sample("StepCount", value: 120)], workouts: [])
        XCTAssertEqual(body["actor"] as? String, "adapter:ios-healthkit")
        XCTAssertEqual(body["source"] as? String, "apple-health")
        XCTAssertEqual(body["device"] as? String, "iPhone")
        XCTAssertEqual((body["samples"] as? [[String: Any]])?.count, 1)
    }

    func testPayloadQuantitySampleFields() {
        let body = HealthPayload.build(actor: "a", device: "iPhone",
                                       samples: [sample("StepCount", value: 120)], workouts: [])
        let s = (body["samples"] as? [[String: Any]])![0]
        XCTAssertEqual(s["uuid"] as? String, "u-StepCount")
        XCTAssertEqual(s["metric"] as? String, "StepCount")
        XCTAssertEqual(s["value"] as? Double, 120)
        XCTAssertEqual(s["unit"] as? String, "count")
        XCTAssertEqual(s["tz_offset_minutes"] as? Int, -240)
        XCTAssertNil(s["category"], "quantity samples omit category")
    }

    func testPayloadCategorySampleOmitsValueUnit() {
        let body = HealthPayload.build(actor: "a", device: "iPhone",
                                       samples: [sample("SleepAnalysis", value: nil, category: "AsleepDeep")],
                                       workouts: [])
        let s = (body["samples"] as? [[String: Any]])![0]
        XCTAssertEqual(s["category"] as? String, "AsleepDeep")
        XCTAssertNil(s["value"], "category samples have no numeric value")
        XCTAssertNil(s["unit"])
    }

    func testPayloadWorkoutFields() {
        let w = HealthWorkoutRecord(uuid: "w1", activity: "37", start: "2026-07-24T06:00:00Z",
                                    end: "2026-07-24T06:30:00Z", energyKcal: 320, distanceM: 5000,
                                    source: "Apple Watch", tzOffsetMinutes: -240)
        let body = HealthPayload.build(actor: "a", device: "iPhone", samples: [], workouts: [w])
        let wd = (body["workouts"] as? [[String: Any]])![0]
        XCTAssertEqual(wd["uuid"] as? String, "w1")
        XCTAssertEqual(wd["energy_kcal"] as? Double, 320)
        XCTAssertEqual(wd["distance_m"] as? Double, 5000)
    }

    // MARK: - Anchor store (Data layer)

    func testAnchorStoreRoundTrip() throws {
        let defaults = UserDefaults(suiteName: "hk.test.\(UUID().uuidString)")!
        let store = HealthAnchorStore(defaults: defaults)
        XCTAssertNil(store.data(for: "StepCount"))
        let blob = Data([1, 2, 3, 4])
        store.setData(blob, for: "StepCount")
        XCTAssertEqual(store.data(for: "StepCount"), blob)
        store.setData(nil, for: "StepCount")
        XCTAssertNil(store.data(for: "StepCount"), "nil clears the anchor")
    }
}
