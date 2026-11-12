import XCTest

/// Navigation probe on the dedicated, unfunded Signet simulator. Never submits
/// an exit or changes the physical device's authentication or wallet state.
final class BatchExitUITests: XCTestCase {
    func testCooperativeAndUnilateralExitRemainSeparate() throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_UI_BATCH_EXIT"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_BATCH_EXIT=1 on the unfunded Signet simulator")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-selectedNetwork", "signet", "-biometricUnlockEnabled", "NO"]
        app.launch()
        let settings = app.buttons["wallet.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 90))
        settings.tap()
        app.buttons["settings.exit"].tap()
        XCTAssertTrue(app.staticTexts["Choose funds"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No available funds"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["exit.continue"].isEnabled)
        XCTAssertFalse(app.buttons["exit.confirm"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Cooperative exit selection"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings.recovery"].tap()
        app.buttons["recovery.unilateral"].tap()
        XCTAssertTrue(app.navigationBars["Unilateral exit"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Check recovery plan"].exists)
        XCTAssertFalse(app.buttons["exit.continue"].exists)
    }
}
