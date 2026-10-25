import XCTest
@testable import Hearthloom

/// Sentry's trace headers may go to the connected node and nowhere else.
final class ObservabilityTests: XCTestCase {

    private func propagates(_ url: String, node: String?) -> Bool {
        Observability.propagationTargets(for: node.flatMap(URL.init(string:))).contains { regex in
            regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
    }

    func testNoNodeMeansNoTraceHeaders() {
        XCTAssertTrue(Observability.propagationTargets(for: nil).isEmpty)
        XCTAssertFalse(propagates("https://node.example.com/v1/stats", node: nil))
    }

    func testOnlyTheConnectedNodeGetsTraceHeaders() {
        let node = "https://node.example.com"
        XCTAssertTrue(propagates("https://node.example.com/v1/ingest/health", node: node))
        XCTAssertTrue(propagates("https://node.example.com", node: node))
        XCTAssertTrue(propagates("https://NODE.example.com/health", node: node))
        XCTAssertFalse(propagates("https://provider.example.com/api/auth/login", node: node),
                       "never to a hosted provider")
        XCTAssertFalse(propagates("https://node.example.com.other.test/v1/stats", node: node),
                       "not to a look-alike host")
        XCTAssertFalse(propagates("http://node.example.com/v1/stats", node: node), "scheme matters")
        XCTAssertFalse(propagates("https://node.example.com:8443/v1/stats", node: node), "port matters")
    }

    func testLocalNodeWithPort() {
        let node = "http://192.168.1.20:43278"
        XCTAssertTrue(propagates("http://192.168.1.20:43278/v1/ingest/capture", node: node))
        XCTAssertFalse(propagates("http://192.168.1.2:43278/v1/ingest/capture", node: node))
        XCTAssertFalse(propagates("http://192.168.1.20:4327/v1/stats", node: node))
    }
}
