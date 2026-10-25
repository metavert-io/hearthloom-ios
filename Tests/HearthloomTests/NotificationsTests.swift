import XCTest
@testable import Hearthloom

final class NotificationsTests: XCTestCase {

    func testParsesRowsAndUnread() {
        let json = """
        {"notifications":[
          {"id":"n1","ts":"2026-07-23T10:00:00Z","severity":"info","origin":"consolidation",
           "title":"Nightly pass done","body":"12 episodes","link":"/pulse","link_label":"View","read_at":null},
          {"id":"n2","ts":"2026-07-23T09:00:00Z","severity":"warn","origin":"llm",
           "title":"LLM budget low","body":"","read_at":"2026-07-23T09:05:00Z"}
        ],"unread":1,"killswitch":false}
        """.data(using: .utf8)!

        let resp = HearthAPI.parseNotifications(json)
        XCTAssertEqual(resp.notifications.count, 2)
        XCTAssertEqual(resp.unread, 1)

        let first = resp.notifications[0]
        XCTAssertEqual(first.id, "n1")
        XCTAssertEqual(first.severity, "info")
        XCTAssertEqual(first.linkLabel, "View")
        XCTAssertTrue(first.isUnread)

        let second = resp.notifications[1]
        XCTAssertFalse(second.isUnread, "read_at present → read")
        XCTAssertNil(second.link)
    }

    func testParsesEmpty() {
        let json = #"{"notifications":[],"unread":0,"killswitch":false}"#.data(using: .utf8)!
        let resp = HearthAPI.parseNotifications(json)
        XCTAssertTrue(resp.notifications.isEmpty)
        XCTAssertEqual(resp.unread, 0)
    }

    func testUnreadFallsBackToCount() {
        // No `unread` key → derive from unread rows.
        let json = """
        {"notifications":[
          {"id":"a","ts":"t","severity":"info","origin":"x","title":"A","body":"","read_at":null},
          {"id":"b","ts":"t","severity":"info","origin":"x","title":"B","body":"","read_at":null}
        ]}
        """.data(using: .utf8)!
        XCTAssertEqual(HearthAPI.parseNotifications(json).unread, 2)
    }

    func testSkipsMalformedRows() {
        let json = #"{"notifications":[{"severity":"info"},{"id":"ok","ts":"t","severity":"info","origin":"x","title":"T","body":""}],"unread":0}"#.data(using: .utf8)!
        let resp = HearthAPI.parseNotifications(json)
        XCTAssertEqual(resp.notifications.count, 1, "row without id is dropped")
        XCTAssertEqual(resp.notifications.first?.id, "ok")
    }
}
