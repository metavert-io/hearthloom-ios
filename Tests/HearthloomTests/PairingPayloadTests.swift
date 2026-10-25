import XCTest
@testable import Hearthloom

final class PairingPayloadTests: XCTestCase {
    func testParsesValidPairingCode() {
        // Exactly what the dashboard's integrations.js encodes.
        let raw = "hearthloom://pair?url=https%3A%2F%2Fnode.example.com&pat=hl_secret123"
        let parsed = PairingPayload.parse(raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.url.host, "node.example.com")
        XCTAssertEqual(parsed?.pat, "hl_secret123")
    }

    func testRejectsWrongScheme() {
        XCTAssertNil(PairingPayload.parse("https://pair?url=x&pat=y"))
    }

    func testRejectsWrongHost() {
        XCTAssertNil(PairingPayload.parse("hearthloom://connect?url=https%3A%2F%2Fn.example&pat=hl_x"))
    }

    func testRejectsMissingPAT() {
        XCTAssertNil(PairingPayload.parse("hearthloom://pair?url=https%3A%2F%2Fn.example"))
    }

    func testRejectsEmptyPAT() {
        XCTAssertNil(PairingPayload.parse("hearthloom://pair?url=https%3A%2F%2Fn.example&pat="))
    }
}
