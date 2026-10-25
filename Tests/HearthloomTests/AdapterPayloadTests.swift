import XCTest
@testable import Hearthloom

final class AdapterPayloadTests: XCTestCase {
    func testContactsPayload() {
        let c = ContactRecord(key: "id1", name: "Ada", emails: ["a@b.c"], phones: ["+1"], org: "Acme", postal: ["1 St"])
        let body = ContactsPayload.build(actor: "adapter:ios-contacts", device: "iPhone", items: [c])
        XCTAssertEqual(body["source"] as? String, "contacts")
        let item = (body["items"] as? [[String: Any]])![0]
        XCTAssertEqual(item["key"] as? String, "id1")
        XCTAssertEqual(item["emails"] as? [String], ["a@b.c"])
        XCTAssertEqual(item["org"] as? String, "Acme")
    }

    func testCalendarPayload() {
        let e = CalendarEventRecord(uid: "e1", title: "Sync", start: "2026-08-16T10:00:00Z",
                                    end: "2026-08-16T11:00:00Z", location: "Room", attendees: ["Bob"], tzOffsetMinutes: -240)
        let body = CalendarPayload.build(actor: "adapter:ios-calendar", device: "iPhone", items: [e])
        XCTAssertEqual(body["source"] as? String, "calendar")
        let item = (body["items"] as? [[String: Any]])![0]
        XCTAssertEqual(item["uid"] as? String, "e1")
        XCTAssertEqual(item["attendees"] as? [String], ["Bob"])
        XCTAssertEqual(item["tz_offset_minutes"] as? Int, -240)
    }

    func testLocationPayloadOpenVisitOmitsEnd() {
        let v = VisitRecord(key: "ios-visits|37.77493|-122.41942|1000", lat: 37.77493, lon: -122.41942,
                            accuracyM: 65, tStart: "2026-08-17T09:00:00Z", tEnd: nil,
                            tzOffsetMinutes: -420, lastSentSignature: nil)
        let body = LocationPayload.build(actor: "adapter:ios-visits", items: [v])
        XCTAssertEqual(body["source"] as? String, "ios-visits")
        let item = (body["items"] as? [[String: Any]])![0]
        XCTAssertEqual(item["key"] as? String, "ios-visits|37.77493|-122.41942|1000")
        XCTAssertEqual(item["lat"] as? Double, 37.77493)
        XCTAssertEqual(item["accuracy_m"] as? Double, 65)
        XCTAssertEqual(item["tz_offset_minutes"] as? Int, -420)
        XCTAssertNil(item["t_end"])   // open visit: no departure yet
    }

    func testLocationPayloadClosedVisitIncludesEnd() {
        let v = VisitRecord(key: "k", lat: 1, lon: 2, accuracyM: nil,
                            tStart: "2026-08-17T09:00:00Z", tEnd: "2026-08-17T10:30:00Z",
                            tzOffsetMinutes: 0, lastSentSignature: nil)
        let item = (LocationPayload.build(actor: "adapter:ios-visits", items: [v])["items"] as? [[String: Any]])![0]
        XCTAssertEqual(item["t_end"] as? String, "2026-08-17T10:30:00Z")
        XCTAssertNil(item["accuracy_m"])   // nil accuracy is omitted
    }

    func testScanPayload() {
        let s = ScanRecord(key: "scan|1000|receipt", kind: "receipt", ocrText: "TOTAL $12.00",
                           capturedAt: "2026-08-17T12:00:00Z", tzOffsetMinutes: -420)
        let body = ScanPayload.build(actor: "adapter:ios-scan", items: [s])
        XCTAssertEqual(body["source"] as? String, "ios-scan")
        let item = (body["items"] as? [[String: Any]])![0]
        XCTAssertEqual(item["kind"] as? String, "receipt")
        XCTAssertEqual(item["ocr_text"] as? String, "TOTAL $12.00")
        XCTAssertEqual(item["captured_at"] as? String, "2026-08-17T12:00:00Z")
        XCTAssertEqual(item["tz_offset_minutes"] as? Int, -420)
    }

    func testFocusPayloadOpenAndClose() {
        let open = FocusSpan(key: "focus|1000", state: "focused", since: "2026-08-17T09:00:00Z",
                             until: nil, openSent: false, closedSent: false)
        let openItem = (FocusPayload.build(actor: "adapter:ios-focus", device: "iPhone", items: [open])["items"] as? [[String: Any]])![0]
        XCTAssertEqual(openItem["state"] as? String, "focused")
        XCTAssertNil(openItem["until"])   // open span omits until

        let closed = FocusSpan(key: "focus|1000", state: "focused", since: "2026-08-17T09:00:00Z",
                               until: "2026-08-17T11:00:00Z", openSent: true, closedSent: false)
        let body = FocusPayload.build(actor: "adapter:ios-focus", device: "iPhone", items: [closed])
        XCTAssertEqual(body["source"] as? String, "ios-focus")
        let closedItem = (body["items"] as? [[String: Any]])![0]
        XCTAssertEqual(closedItem["until"] as? String, "2026-08-17T11:00:00Z")
    }

    func testVisitSignatureTracksClose() {
        let open = VisitRecord(key: "k", lat: 1, lon: 2, accuracyM: nil, tStart: "t", tEnd: nil, tzOffsetMinutes: 0, lastSentSignature: nil)
        let closed = VisitRecord(key: "k", lat: 1, lon: 2, accuracyM: nil, tStart: "t", tEnd: "t2", tzOffsetMinutes: 0, lastSentSignature: nil)
        XCTAssertEqual(LocationVisitsIngest.signature(open), "open")
        XCTAssertEqual(LocationVisitsIngest.signature(closed), "t2")
        XCTAssertNotEqual(LocationVisitsIngest.signature(open), LocationVisitsIngest.signature(closed))
    }
}
