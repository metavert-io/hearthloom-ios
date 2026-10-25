import XCTest

/// The Connect screen with no node: self-hosting comes first, credentials wait
/// for a reached server, and the hosted provider is listed but never chosen
/// for you. The listed provider is pinned through the launch environment
/// (`HLIOS_UITEST_PROVIDER_*`, honoured only with `--uitest-reset`) so the
/// result doesn't depend on the build's provider settings. Nothing here needs
/// a network except one address that cannot resolve (`.invalid`).
final class ConnectScreenUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(providerURL: String = "https://provider.example.com") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launchEnvironment["HLIOS_UITEST_PROVIDER_NAME"] = "Example Host"
        app.launchEnvironment["HLIOS_UITEST_PROVIDER_URL"] = providerURL
        app.launch()
        return app
    }

    func testFirstScreenLeadsWithPairingThenAddressThenProviders() throws {
        let app = launch()
        let pair = app.buttons["connect.pairqr"].firstMatch
        let address = app.buttons["connect.address"].firstMatch
        let provider = app.buttons["connect.provider"].firstMatch
        XCTAssertTrue(pair.waitForExistence(timeout: 10), "pairing button missing")
        XCTAssertTrue(address.exists, "server address button missing")
        XCTAssertTrue(provider.exists, "hosted provider missing")

        // Top to bottom: pair, server address, then the hosted provider.
        XCTAssertLessThan(pair.frame.minY, address.frame.minY)
        XCTAssertLessThan(address.frame.minY, provider.frame.minY)
        XCTAssertTrue(app.staticTexts["Hosted providers"].exists
                      || app.staticTexts["HOSTED PROVIDERS"].exists)
        XCTAssertTrue(provider.label.contains("Example Host"))

        // Nothing is preselected: no credential fields on the first screen.
        XCTAssertEqual(app.secureTextFields.count, 0)
        XCTAssertEqual(app.textFields.count, 0)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "connect-first-screen"; shot.lifetime = .keepAlways
        add(shot)
    }

    func testCredentialsWaitUntilTheServerIsReached() throws {
        let app = launch()
        let address = app.buttons["connect.address"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()

        let field = app.textFields["server.address"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "address field missing")
        let next = app.buttons["server.continue"].firstMatch
        XCTAssertFalse(next.isEnabled, "nothing typed yet")
        XCTAssertEqual(app.secureTextFields.count, 0, "no password before a server is known")

        // An address that can't resolve: the app says so and still asks for
        // no credentials.
        field.tap()
        app.typeText("node.example.invalid")
        XCTAssertTrue(next.isEnabled)
        next.tap()
        let error = app.descendants(matching: .any)["connect.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 20), "expected a reachability error")
        XCTAssertEqual(app.secureTextFields.count, 0)
        XCTAssertFalse(app.descendants(matching: .any)["login.usetoken"].exists)

        app.buttons["connect.back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["connect.pairqr"].waitForExistence(timeout: 5))
    }

    func testHostedProviderOpensItsOwnSignIn() throws {
        let app = launch()
        let provider = app.buttons["connect.provider"].firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 10))
        provider.tap()

        XCTAssertTrue(app.staticTexts["Sign in to Example Host"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["provider.email"].exists)
        XCTAssertTrue(app.secureTextFields["provider.password"].exists)
        XCTAssertFalse(app.buttons["provider.signin"].isEnabled, "nothing typed yet")
        XCTAssertTrue(app.buttons["provider.create"].exists, "create-account path missing")

        app.buttons["connect.back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["connect.pairqr"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.secureTextFields.count, 0)
    }

    func testEmptyProviderURLHidesHostedProviders() throws {
        let app = launch(providerURL: "")
        XCTAssertTrue(app.buttons["connect.pairqr"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connect.address"].exists)
        XCTAssertFalse(app.buttons["connect.provider"].exists)
        XCTAssertFalse(app.staticTexts["Hosted providers"].exists
                       || app.staticTexts["HOSTED PROVIDERS"].exists)
    }
}
