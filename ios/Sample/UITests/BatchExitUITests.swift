import XCTest

/// Navigation probe on the dedicated, unfunded Signet simulator. Never submits
/// an exit or changes the physical device's authentication or wallet state.
final class BatchExitUITests: XCTestCase {
    func testUnilateralExitReplacesOldExitRoute() throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_UI_BATCH_EXIT"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_BATCH_EXIT=1 on the unfunded Signet simulator")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-selectedNetwork", "signet", "-biometricUnlockEnabled", "NO"]
        app.launchEnvironment = ["WAVELENGTH_AUTOCREATE": "1"]
        app.launch()
        let settings = app.buttons["wallet.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 90))
        settings.tap()
        app.buttons["settings.exit"].tap()
        XCTAssertTrue(app.navigationBars["Unilateral exit"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No available funds"].waitForExistence(timeout: 30))
        let review = app.buttons["unilateral.review"]
        XCTAssertFalse(review.exists && review.isEnabled)
        XCTAssertFalse(app.buttons["unilateral.selectAll"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings.recovery"].tap()
        XCTAssertTrue(app.navigationBars["Recovery"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Unilateral exit"].exists)
    }
}
