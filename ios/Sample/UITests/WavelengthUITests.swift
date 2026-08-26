import XCTest

final class WavelengthUITests: XCTestCase {
    private var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    private func launchRegtestApp() throws -> XCUIApplication {
        guard environment["WAVELENGTH_UI_REGTEST"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_REGTEST=1 and the endpoint variables to run the live regtest UI tests")
        }
        let operatorAddress = try XCTUnwrap(environment["WAVELENGTH_OPERATOR_ADDRESS"])
        let swapAddress = try XCTUnwrap(environment["WAVELENGTH_SWAP_ADDRESS"])
        let esploraURL = try XCTUnwrap(environment["WAVELENGTH_ESPLORA_URL"])

        let app = XCUIApplication()
        app.launchEnvironment = [
            "WAVELENGTH_REGTEST": "1",
            "WAVELENGTH_AUTOCREATE": "1",
            "WAVELENGTH_OPERATOR_ADDRESS": operatorAddress,
            "WAVELENGTH_SWAP_ADDRESS": swapAddress,
            "WAVELENGTH_ESPLORA_URL": esploraURL,
        ]
        app.launch()

        let receive = app.buttons["wallet.receive"]
        XCTAssertTrue(receive.waitForExistence(timeout: 30), "Wallet did not become ready")
        return app
    }

    func testCreateOnchainRequest() throws {
        let app = try launchRegtestApp()
        app.buttons["wallet.receive"].tap()

        let onchain = app.buttons["On-chain"]
        XCTAssertTrue(onchain.waitForExistence(timeout: 5))
        onchain.tap()

        let create = app.buttons["receive.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()

        let request = app.staticTexts["receive.request"]
        XCTAssertTrue(request.waitForExistence(timeout: 20))
        XCTAssertTrue(request.label.hasPrefix("bcrt1"), request.label)
        app.buttons["receive.copy"].tap()
        print("WAVELENGTH_ONCHAIN_REQUEST=\(request.label)")
    }

    func testCreateLightningRequest() throws {
        let app = try launchRegtestApp()
        app.buttons["wallet.receive"].tap()

        let amount = app.textFields["receive.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("50000")

        let create = app.buttons["receive.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        if !create.isHittable {
            app.swipeUp()
        }
        create.tap()

        let request = app.staticTexts["receive.request"]
        XCTAssertTrue(request.waitForExistence(timeout: 20))
        XCTAssertTrue(request.label.lowercased().hasPrefix("lnbcrt"), request.label)
        app.buttons["receive.copy"].tap()
        print("WAVELENGTH_LIGHTNING_REQUEST=\(request.label)")
    }

    func testFundedWalletShowsBalanceAndActivity() throws {
        guard environment["WAVELENGTH_UI_EXTERNAL_FUNDING"] == "1" else {
            throw XCTSkip("This test prints an address and waits for external regtest funding")
        }
        let app = try launchRegtestApp()

        app.buttons["wallet.receive"].tap()
        let onchain = app.buttons["On-chain"]
        XCTAssertTrue(onchain.waitForExistence(timeout: 5))
        onchain.tap()
        app.buttons["receive.create"].tap()
        let request = app.staticTexts["receive.request"]
        XCTAssertTrue(request.waitForExistence(timeout: 20))
        print("WAVELENGTH_FUND_THIS_ADDRESS=\(request.label)")
        app.buttons["Done"].tap()

        let balance = app.staticTexts["wallet.balance"]
        XCTAssertTrue(balance.waitForExistence(timeout: 30))
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline && balance.label.contains("Incoming, 0 sats") {
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        XCTAssertFalse(balance.label.contains("Incoming, 0 sats"), balance.label)

        app.tabBars.buttons["Activity"].tap()
        let entry = app.descendants(matching: .any)["activity.entry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Activity Details"].waitForExistence(timeout: 10))
    }
}
