import XCTest

/// Uses an unfunded Signet wallet on a dedicated simulator. No payment or
/// refresh is submitted; the test exercises actual native diagnostics and UI.
final class DiagnosticsUITests: XCTestCase {
    func testInspectInventoryAndFilterNativeLogs() throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_UI_DIAGNOSTICS"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_DIAGNOSTICS=1 for the Signet diagnostics UI probe")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        // This dedicated unfunded fixture uses the app's existing optional
        // authentication setting. Physical-device authentication is unchanged.
        app.launchArguments = ["-selectedNetwork", "signet", "-biometricUnlockEnabled", "NO"]
        app.launch()
        let create = app.buttons["Create wallet"]
        if create.waitForExistence(timeout: 20) {
            create.tap()
            let saved = app.switches["I saved my recovery words"]
            XCTAssertTrue(saved.waitForExistence(timeout: 45))
            for _ in 0..<6 where !saved.isHittable { app.swipeUp() }
            app.swipeUp()
            if saved.switches.firstMatch.exists { saved.switches.firstMatch.tap() }
            else { saved.tap() }
            let done = app.buttons["Done"]
            if !done.isHittable { app.swipeUp() }
            XCTAssertTrue(done.isEnabled)
            done.tap()
        }
        let receive = app.buttons["wallet.receive"]
        XCTAssertTrue(receive.waitForExistence(timeout: 90))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: receive)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed)
        app.buttons["wallet.settings"].tap()
        let diagnostics = app.buttons["settings.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        if !diagnostics.isHittable { app.swipeUp() }
        diagnostics.tap()
        XCTAssertTrue(app.buttons["diagnostics.vtxos"].waitForExistence(timeout: 10))
        attach(app, name: "Diagnostics overview")
        app.buttons["diagnostics.vtxos"].tap()
        XCTAssertTrue(app.textFields["diagnostics.vtxoSearch"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No matching VTXOs"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["diagnostics.error"].exists)
        attach(app, name: "Unfunded VTXO inventory")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["diagnostics.logs"].tap()
        let filter = app.textFields["diagnostics.logFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        filter.tap()
        filter.typeText("wAvEd")
        let count = app.staticTexts["diagnostics.logCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        let populated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "0 matches"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [populated], timeout: 15), .completed,
                       "Mixed-case filter did not find the native Starting waved log")
        XCTAssertFalse(app.staticTexts["diagnostics.error"].exists)
        app.buttons["Pause logs"].tap()
        XCTAssertTrue(app.buttons["Resume logs"].exists)
        attach(app, name: "Case-insensitive native log filter")
        app.buttons["Resume logs"].tap()
        filter.tap()
        filter.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "\n")
        let scroll = app.scrollViews["diagnostics.logScroll"]
        scroll.swipeDown()
        let follow = app.buttons["diagnostics.follow"]
        XCTAssertEqual(follow.value as? String, "Browsing")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "diagnostics.log."))
        let anchor = try XCTUnwrap(rows.allElementsBoundByIndex.first(where: { $0.isHittable }))
        let anchorID = anchor.identifier
        let previousY = anchor.frame.minY
        let previousLatest = count.value as? String ?? ""
        XCTAssertFalse(previousLatest.isEmpty)
        app.buttons["Log options"].tap()
        app.buttons["Add marker"].tap()
        let appended = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let latest = count.value as? String ?? ""
            return !latest.isEmpty && latest != previousLatest
        }, object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [appended], timeout: 10), .completed)
        let sameRow = app.buttons[anchorID]
        XCTAssertTrue(sameRow.isHittable)
        XCTAssertEqual(sameRow.frame.minY, previousY, accuracy: 2,
                       "Appending logs moved the row being read")
        XCTAssertEqual(follow.value as? String, "Browsing")
        follow.tap()
        XCTAssertEqual(follow.value as? String, "Following")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
