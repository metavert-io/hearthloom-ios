import XCTest

/// What pressing the Lock Screen / Control Center control leads to: the app
/// comes forward with the capture field up, over whatever screen it is on —
/// here the signed-out Connect screen, so nothing needs a node. The capture is
/// queued on the simulator and never uploaded.
final class CaptureControlUITests: XCTestCase {
    func testControlOpensCaptureFieldAndSaves() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-capture"]
        app.launch()

        let save = app.buttons["quickcapture.save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "capture sheet didn't open")
        XCTAssertFalse(save.isEnabled, "nothing to save yet")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "keyboard should already be up")
        app.typeText("ask Ada about the lease")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "capture-sheet"; shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), "sheet should close once the capture is queued")
    }
}
