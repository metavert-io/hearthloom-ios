import XCTest
@testable import Hearthloom

final class ConnectionTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let original = Connection(
            baseURL: URL(string: "https://node.example.com")!,
            deviceToken: "hl_pat_secret",
            displayName: "My iPhone",
            origin: .selfHostSignIn)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Connection.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.deviceToken, "hl_pat_secret")
        XCTAssertEqual(decoded.baseURL.absoluteString, "https://node.example.com")
    }

    func testWebSessionCapabilityAllOrigins() {
        func conn(_ o: Connection.Origin) -> Connection {
            Connection(baseURL: URL(string: "https://x.com")!, deviceToken: "t",
                       displayName: "d", origin: o)
        }
        // The node's session-from-key endpoint lets every origin mint a
        // webview session from its durable PAT — including token-only ones.
        for o: Connection.Origin in [.selfHostSignIn, .selfHostPastedPAT,
                                     .hostedNew, .hostedSignIn] {
            XCTAssertTrue(conn(o).canEstablishWebSession)
        }
    }

    /// Stored in the Keychain with every connection: renaming a case must
    /// never change what it decodes from.
    func testOriginRawValuesNeverChange() throws {
        XCTAssertEqual(Connection.Origin.selfHostSignIn.rawValue, "selfHostSignIn")
        XCTAssertEqual(Connection.Origin.selfHostPastedPAT.rawValue, "selfHostPastedPAT")
        XCTAssertEqual(Connection.Origin.hostedNew.rawValue, "hearthlaunchNew")
        XCTAssertEqual(Connection.Origin.hostedSignIn.rawValue, "hearthlaunchSignIn")
        let stored = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","baseURL":"https:\/\/node.example.com","deviceToken":"t","displayName":"d","origin":"hearthlaunchSignIn"}"#
        let decoded = try JSONDecoder().decode(Connection.self, from: Data(stored.utf8))
        XCTAssertEqual(decoded.origin, .hostedSignIn)
    }

    func testDistinctIDs() {
        let a = Connection(baseURL: URL(string: "https://x.com")!, deviceToken: "t",
                           displayName: "d", origin: .selfHostSignIn)
        let b = Connection(baseURL: URL(string: "https://x.com")!, deviceToken: "t",
                           displayName: "d", origin: .selfHostSignIn)
        XCTAssertNotEqual(a.id, b.id, "each connection gets a fresh id for multi-connection keying")
    }
}
