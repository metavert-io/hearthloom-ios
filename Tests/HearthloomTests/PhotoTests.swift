import XCTest
@testable import Hearthloom

final class PhotoTests: XCTestCase {

    func testStableKeyIsCaptureTimePlusFilename() {
        let d = Date(timeIntervalSince1970: 1_784_849_400)   // 2026-07-23T23:30:00Z
        XCTAssertEqual(PhotoPayload.key(takenAt: d, filename: "IMG_1234.HEIC"),
                       "1784849400|IMG_1234.HEIC")
    }

    private func sample() -> PhotoLocationRecord {
        PhotoLocationRecord(
            key: "1784849400|IMG_1.HEIC", filename: "IMG_1.HEIC",
            takenAt: "2026-07-23T23:30:00Z", tzOffsetMinutes: -240,
            lat: 12.3456, lon: -45.6789)
    }

    func testPayloadTopLevel() {
        let body = PhotoPayload.build(actor: "adapter:ios-photos", device: "iPhone",
                                      photos: [sample()])
        XCTAssertEqual(body["actor"] as? String, "adapter:ios-photos")
        XCTAssertEqual(body["source"] as? String, "photos")
        XCTAssertEqual((body["photos"] as? [[String: Any]])?.count, 1)
    }

    func testPayloadPhotoFields() {
        let p = (PhotoPayload.build(actor: "a", device: "iPhone", photos: [sample()])["photos"]
                 as? [[String: Any]])![0]
        XCTAssertEqual(p["key"] as? String, "1784849400|IMG_1.HEIC")
        XCTAssertEqual(p["filename"] as? String, "IMG_1.HEIC")
        XCTAssertEqual(p["taken_at"] as? String, "2026-07-23T23:30:00Z")
        XCTAssertEqual(p["tz_offset_minutes"] as? Int, -240)
        XCTAssertEqual(p["lat"] as? Double, 12.3456)
        XCTAssertEqual(p["lon"] as? Double, -45.6789)
    }

    func testEmptyPhotos() {
        let body = PhotoPayload.build(actor: "a", device: "d", photos: [])
        XCTAssertEqual((body["photos"] as? [[String: Any]])?.count, 0)
    }
}
