import XCTest

/// Drives the Connect flow end-to-end against a real node — Enter server
/// address → Continue (the app reaches the node) → device token → Connect —
/// then (second test) captures a thought through Settings → Quick capture.
/// Node URL + PAT come from the test-runner environment (`HLIOS_BASE_URL` /
/// `HLIOS_PAT`, injected as `TEST_RUNNER_HLIOS_BASE_URL` /
/// `TEST_RUNNER_HLIOS_PAT`). Skips cleanly when they're absent so the suite
/// stays portable; ConnectScreenUITests covers the screen with no node.
final class ConnectFlowUITests: XCTestCase {

    private var baseURL = ""
    private var pat = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        baseURL = env["HLIOS_BASE_URL"] ?? ""
        pat = env["HLIOS_PAT"] ?? ""
        try XCTSkipIf(baseURL.isEmpty || pat.isEmpty,
                      "Set TEST_RUNNER_HLIOS_BASE_URL and TEST_RUNNER_HLIOS_PAT to run the live UI test.")
    }

    func testPastePATConnectThenCapture() throws {
        connect()
    }

    /// Settings → Quick capture: type a thought, capture it, and see it upload.
    /// Files one real capture on the node under test.
    func testQuickCaptureUploads() throws {
        let app = connect()
        app.tabBars.buttons["Settings"].tap()
        // The row sits below the data-source checklist — scroll it into view.
        let row = app.staticTexts["Quick capture"].firstMatch
        for _ in 0..<4 where !row.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(row.exists, "Quick capture row missing")
        row.tap()

        // LabeledContent rows surface as one element ("Last upload, Never").
        func text(_ fragment: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
        }
        let never = text("Never")
        XCTAssertTrue(never.waitForExistence(timeout: 5), "expected no uploads yet")
        let input = field(app, "capture.field")
        XCTAssertTrue(input.waitForExistence(timeout: 5), "capture field missing")
        focusAndType(app, input, "call the plumber about the upstairs tap")
        app.buttons["capture.save"].firstMatch.tap()

        XCTAssertTrue(never.waitForNonExistence(timeout: 15), "the capture didn't upload")
        XCTAssertTrue(text("Ready").exists, "capture key wasn't created")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "quick-capture-uploaded"; shot.lifetime = .keepAlways
        add(shot)

        // The setup checklist: not added on a fresh simulator, with steps shown.
        app.swipeUp()
        XCTAssertTrue(text("Not added yet").waitForExistence(timeout: 5), "setup checklist missing")
        app.buttons["Lock Screen"].firstMatch.tap()
        XCTAssertTrue(text("Customize").waitForExistence(timeout: 3))
        let setup = XCTAttachment(screenshot: app.screenshot())
        setup.name = "quick-capture-setup"; setup.lifetime = .keepAlways
        add(setup)
    }

    @discardableResult
    private func connect() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        // Connect screen → "Enter server address".
        let enterAddress = app.buttons["connect.address"].firstMatch
        XCTAssertTrue(enterAddress.waitForExistence(timeout: 10), "Connect screen didn't appear")
        enterAddress.tap()

        // Type the node address and continue: the app reaches the node first.
        let address = field(app, "server.address")
        XCTAssertTrue(address.waitForExistence(timeout: 5), "address field missing")
        focusAndType(app, address, baseURL)
        app.buttons["server.continue"].firstMatch.tap()

        // Node reached → its sign-in form → "Use a device token instead".
        let useToken = app.descendants(matching: .any)["login.usetoken"].firstMatch
        XCTAssertTrue(useToken.waitForExistence(timeout: 15), "the app didn't reach the node")
        useToken.tap()

        let token = field(app, "token.value")
        XCTAssertTrue(token.waitForExistence(timeout: 5), "token field missing")
        focusAndType(app, token, pat)

        // Connect (probe /health → validate PAT → adopt).
        let connect = app.buttons["token.connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()

        // The shell renders: the tab bar appears.
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 20),
                      "shell tab bar didn't appear after connect")

        // Shell rendered end-to-end: the other native tabs are present too.
        XCTAssertTrue(app.tabBars.buttons["Alerts"].exists, "Alerts tab missing")
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists, "Settings tab missing")
        return app
    }

    /// Focus a text-entry element via a center coordinate tap (reliable for
    /// multi-line TextFields that don't focus on a plain `.tap()`), then type
    /// into whatever holds focus.
    private func focusAndType(_ app: XCUIApplication, _ element: XCUIElement, _ text: String) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.keyboards.element.waitForExistence(timeout: 3)
        app.typeText(text)
    }

    /// Locate a text-entry element by identifier across TextField/SecureField/TextView.
    private func field(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let tf = app.textFields[id]
        if tf.exists { return tf }
        let tv = app.textViews[id]
        if tv.exists { return tv }
        return app.descendants(matching: .any)[id].firstMatch
    }
}
