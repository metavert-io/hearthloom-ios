import XCTest
@testable import Hearthloom

final class HostedProviderClientTests: XCTestCase {

    func testParseAuthenticatedWithMemberships() throws {
        let json = """
        {"accessToken":"tok","refreshToken":"r","user":{"email":"ada@example.com"},
         "memberships":[
           {"tenantId":"t1","tenantName":"Root","tenantSlug":"root","role":"owner","isRoot":true},
           {"tenantId":"t2","tenantName":"Team","tenantSlug":"team","role":"member","isRoot":false}
         ]}
        """.data(using: .utf8)!
        guard case .authenticated(let session) = try HostedProviderClient.parseAuthOutcome(json) else {
            return XCTFail("expected authenticated")
        }
        XCTAssertEqual(session.accessToken, "tok")
        XCTAssertEqual(session.memberships.count, 2)
        XCTAssertEqual(session.defaultTenant?.tenantId, "t1", "root membership is the default")
    }

    func testParseMFARequired() throws {
        let json = #"{"mfaRequired":true,"mfaToken":"mfa-123"}"#.data(using: .utf8)!
        guard case .mfaRequired(let token) = try HostedProviderClient.parseAuthOutcome(json) else {
            return XCTFail("expected mfaRequired")
        }
        XCTAssertEqual(token, "mfa-123")
    }

    func testParseAuthThrowsWhenNeither() {
        let json = #"{"error":"bad"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try HostedProviderClient.parseAuthOutcome(json))
    }

    func testDefaultTenantFallsBackToFirstWhenNoRoot() throws {
        let json = """
        {"accessToken":"t","memberships":[
          {"tenantId":"only","tenantName":"X","tenantSlug":"x","role":"member","isRoot":false}]}
        """.data(using: .utf8)!
        guard case .authenticated(let s) = try HostedProviderClient.parseAuthOutcome(json) else {
            return XCTFail()
        }
        XCTAssertEqual(s.defaultTenant?.tenantId, "only")
    }

    func testParseInstancesWrappedAndBare() {
        let wrapped = #"{"instances":[{"id":"i1","name":"brain","url":"https://node.example.com","ready":true,"status":"ready"}]}"#.data(using: .utf8)!
        let a = HostedProviderClient.parseInstances(wrapped)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].id, "i1")
        XCTAssertEqual(a[0].url?.absoluteString, "https://node.example.com")
        XCTAssertTrue(a[0].ready)

        let bare = #"[{"id":"i2","nodeName":"node","status":"ready"}]"#.data(using: .utf8)!
        let b = HostedProviderClient.parseInstances(bare)
        XCTAssertEqual(b.first?.id, "i2")
        XCTAssertEqual(b.first?.name, "node", "falls back to nodeName")
        XCTAssertTrue(b.first?.ready ?? false, "status=ready implies ready")
    }

    func testParseInstancesSkipsMalformed() {
        let json = #"{"instances":[{"name":"no-id"},{"id":"ok"}]}"#.data(using: .utf8)!
        let a = HostedProviderClient.parseInstances(json)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a.first?.id, "ok")
    }

    func testClientUsesTheBaseItIsGiven() {
        let client = HostedProviderClient(base: URL(string: "https://provider.example.com")!)
        XCTAssertEqual(client.base.absoluteString, "https://provider.example.com")
    }

    // MARK: - The listed provider (build settings → Connect screen)

    func testProviderFromBuildSettings() {
        let p = HostedProvider.configured(name: "Example Host", url: "https://provider.example.com")
        XCTAssertEqual(p?.name, "Example Host")
        XCTAssertEqual(p?.url.absoluteString, "https://provider.example.com")
    }

    func testBlankProviderURLListsNone() {
        XCTAssertNil(HostedProvider.configured(name: "Example Host", url: ""))
        XCTAssertNil(HostedProvider.configured(name: "Example Host", url: "   "))
        XCTAssertNil(HostedProvider.configured(name: "Example Host", url: nil))
    }

    func testBlankProviderNameFallsBackToHost() {
        XCTAssertEqual(HostedProvider.configured(name: " ", url: "provider.example.com/")?.name,
                       "provider.example.com")
    }

    func testTheAppListsTheConfiguredProvider() {
        // Config/Signing.xcconfig → Info.plist. The committed default lists a
        // provider; a developer may blank the URL to hide it.
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertNotNil(info[HostedProvider.urlKey], "Info.plist should carry the provider URL key")
        XCTAssertEqual(HostedProvider.listed,
                       HostedProvider.configured(name: info[HostedProvider.nameKey] as? String,
                                                 url: info[HostedProvider.urlKey] as? String))
    }

    // MARK: - Self-hosting comes first

    @MainActor
    func testConnectStartsWithNothingChosen() {
        let flow = LoginFlow()
        XCTAssertEqual(flow.step, .start)
        XCTAssertNil(flow.provider, "never defaults to a hosted provider")
    }

    @MainActor
    func testChoosingAProviderAndGoingBackForgetsIt() {
        let flow = LoginFlow()
        let hosted = HostedProvider(name: "Example Host", url: URL(string: "https://provider.example.com")!)
        flow.chooseHosted(hosted)
        XCTAssertEqual(flow.step, .providerSignIn)
        XCTAssertEqual(flow.hostedProvider, hosted)
        flow.createAccountInstead()
        flow.back()
        XCTAssertEqual(flow.step, .providerSignIn)
        flow.back()
        XCTAssertEqual(flow.step, .start)
        XCTAssertNil(flow.provider)
    }

    @MainActor
    func testServerCredentialsWaitForAReachedServer() {
        let flow = LoginFlow()
        flow.enterServerAddress()
        XCTAssertEqual(flow.step, .serverAddress)
        XCTAssertFalse(flow.canContinueToServer)
        flow.serverAddress = "node.example.com"
        XCTAssertTrue(flow.canContinueToServer)
        flow.pasteToken = "hl_token"
        XCTAssertFalse(flow.canPaste, "a token needs a server the app has reached")
        XCTAssertNil(flow.serverURL)
    }
}
