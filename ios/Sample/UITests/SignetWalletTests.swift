import XCTest

/// Opt-in smoke coverage against the pinned binding and configured signet services.
/// Requests are created, but this test never funds the wallet or sends a payment.
final class SignetWalletTests: XCTestCase {
    func testMainnetSelectionCanBeCancelledWithoutChangingWallets() throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_UI_SIGNET"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_SIGNET=1 to run the live signet smoke test")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-selectedNetwork", "signet"]
        app.launch()
        waitForWallet(app)
        app.buttons["wallet.settings"].tap()
        app.buttons["wallet.network"].tap()
        app.buttons["network.mainnet"].tap()
        XCTAssertTrue(app.buttons["network.confirmMainnet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mainnet uses real bitcoin."].exists)
        XCTAssertEqual(app.alerts.count, 0)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Mainnet inline confirmation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["network.confirmMainnet"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["wallet.network"].label.contains("Signet"))
    }

    func testRequestsSurviveForegroundAndProcessRestart() throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_UI_SIGNET"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_SIGNET=1 to run the live signet smoke test")
        }
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-selectedNetwork", "signet"]
        app.launchEnvironment = ["WAVELENGTH_AUTOCREATE": "1"]
        app.launch()
        waitForWallet(app)

        app.buttons["wallet.receive"].tap()
        XCTAssertTrue(app.buttons["On-chain"].waitForExistence(timeout: 10))
        app.buttons["On-chain"].tap()
        app.buttons["receive.create"].tap()
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 45))
        app.buttons["Details"].tap()
        let request = app.staticTexts["receive.request"]
        XCTAssertTrue(request.waitForExistence(timeout: 30))
        XCTAssertTrue(request.label.hasPrefix("tb1"))
        app.buttons["Close"].tap()

        app.buttons["wallet.receive"].tap()
        let amount = app.textFields["receive.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("50000")
        let memo = "Signet smoke \(UUID().uuidString)"
        app.buttons["Note"].tap()
        app.textFields["receive.memo"].tap()
        app.textFields["receive.memo"].typeText(memo)
        let create = app.buttons["receive.create"]
        if !create.isHittable { app.swipeUp() }
        create.tap()
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 45))
        app.buttons["Details"].tap()
        XCTAssertTrue(request.waitForExistence(timeout: 45))
        XCTAssertTrue(request.label.lowercased().hasPrefix("lntb"))
        let invoice = request.label
        let copy = app.buttons["receive.copy"]
        for _ in 0..<5 where !copy.exists || !copy.isHittable { app.swipeUp() }
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        app.buttons["Close"].tap()

        // Pasting must not also trigger the scanner in the same Form row.
        // A long invoice stays inside the editor so review remains visible.
        app.buttons["wallet.send"].tap()
        app.buttons["send.paste"].tap()
        let destination = app.textFields["send.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        let pasted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", invoice),
            object: destination
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 5), .completed,
                       "The pasted request did not match the copied invoice")
        XCTAssertTrue(app.buttons["send.review"].isHittable)
        app.buttons["Close"].tap()

        // A UI lifecycle transition tests foreground recovery, not OS wake or
        // guaranteed execution while suspended.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        waitForWallet(app)
        assertInvoice(app, memo: memo, invoice: invoice)

        // AUTOCREATE is removed so losing the existing wallet cannot silently
        // pass by creating a replacement on the second launch.
        app.terminate()
        app.launchEnvironment = [:]
        app.launch()
        waitForWallet(app)
        assertInvoice(app, memo: memo, invoice: invoice)
    }

    private func waitForWallet(_ app: XCUIApplication) {
        let receive = app.buttons["wallet.receive"]
        XCTAssertTrue(receive.waitForExistence(timeout: 90), "Wallet did not open")
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: receive
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed,
                       "Wallet did not finish syncing")
    }

    private func assertInvoice(_ app: XCUIApplication, memo: String, invoice: String) {
        // Activity is on Home. Match the durable request by its unique note.
        let matching = app.buttons.matching(identifier: "activity.entry").matching(
            NSPredicate(format: "label CONTAINS %@", memo)
        )
        let entry = matching.firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30), "Receive was not recovered")
        entry.tap()
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 45))
        app.buttons["Details"].tap()
        let original = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", invoice)
        ).firstMatch
        for _ in 0..<5 where !original.exists { app.swipeUp() }
        XCTAssertTrue(original.waitForExistence(timeout: 10),
                      "Recovered receive did not retain its original invoice")
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }
}
