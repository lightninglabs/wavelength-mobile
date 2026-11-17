import XCTest

/// Offline form coverage. Never starts, creates or funds a wallet.
final class MaxSendUITests: XCTestCase {
    func testMaximumHidesAndRestoresAmountOnBothRails() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--send-form-test", "-selectedNetwork", "signet"]
        app.launch()
        let destination = app.textFields["send.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.tap()
        destination.typeText("tb1ptest")
        checkAmountSwitch(app, amount: "1234", screenshot: "On-chain Max")
        destination.tap()
        // The first test left the caret at the destination's end. Clear it
        // through keyboard input without granting clipboard access.
        destination.doubleTap()
        if app.menuItems["Select All"].exists { app.menuItems["Select All"].tap() }
        let old = destination.value as? String ?? ""
        destination.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        destination.typeText(amountlessInvoice)
        XCTAssertTrue(app.buttons["send.changeInvoice"].waitForExistence(timeout: 10))
        checkAmountSwitch(app, amount: "5678", screenshot: "Lightning Max")
    }

    private func checkAmountSwitch(_ app: XCUIApplication, amount: String, screenshot: String) {
        let field = app.textFields["send.amount"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(amount)
        let maximum = app.switches["send.useAvailableBalance"]
        XCTAssertTrue(maximum.exists)
        maximum.tap()
        XCTAssertFalse(field.exists, "Max must not leave an editable amount on screen")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = screenshot
        image.lifetime = .keepAlways
        add(image)
        maximum.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, amount)
    }

    // Synthetic key and payment hash. Valid for decoding, never payable.
    private let amountlessInvoice = "lntbs1p40e9fppp5zvqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqdq6f4shsgrnv4hxggz4fys8getnwsxqxfvcqcqmzvq5vkzy2rh9087u875y3k6jg4qvwen2fdgn9j52qxwnsaw04v5a0snm65p4wr9fh5y6zalsqwm7c4ae7rtcgt8rzujh6ud5rts85gpan8rgz"
}
