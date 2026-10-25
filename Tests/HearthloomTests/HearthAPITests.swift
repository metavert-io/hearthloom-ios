import XCTest
@testable import Hearthloom

final class HearthAPITests: XCTestCase {

    // MARK: - URL normalization

    func testNormalizeAddsHTTPS() {
        XCTAssertEqual(HearthAPI.normalize("example.com")?.absoluteString, "https://example.com")
    }

    func testNormalizeKeepsScheme() {
        XCTAssertEqual(HearthAPI.normalize("http://192.168.1.20:43278")?.absoluteString,
                       "http://192.168.1.20:43278")
    }

    func testNormalizeStripsTrailingSlashes() {
        XCTAssertEqual(HearthAPI.normalize("https://node.example.com///")?.absoluteString,
                       "https://node.example.com")
    }

    func testNormalizeTrimsWhitespace() {
        XCTAssertEqual(HearthAPI.normalize("  node.example.com  ")?.absoluteString,
                       "https://node.example.com")
    }

    func testNormalizeRejectsEmpty() {
        XCTAssertNil(HearthAPI.normalize(""))
        XCTAssertNil(HearthAPI.normalize("   "))
    }

    func testNormalizeRejectsSchemeOnly() {
        XCTAssertNil(HearthAPI.normalize("https://"))
    }

    // MARK: - RFC3339 formatting

    func testRFC3339FormatNoFractionalSeconds() {
        // 2026-07-23T23:30:00Z  (1_784_849_400 = that instant)
        let date = Date(timeIntervalSince1970: 1_784_849_400)
        let s = HearthAPI.rfc3339(date)
        XCTAssertTrue(s.hasSuffix("Z"), "expected UTC Z suffix, got \(s)")
        XCTAssertFalse(s.contains("."), "expected no fractional seconds, got \(s)")
        XCTAssertEqual(s, "2026-07-23T23:30:00Z")
    }

}
