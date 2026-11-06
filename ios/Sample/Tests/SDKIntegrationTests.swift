import XCTest
import WalletKit

/// Live quotes use disposable, unfunded wallets. No payment is dispatched.
final class SDKIntegrationTests: XCTestCase {
    func testMicroPaymentQuoteUsesCreditDefaults() async throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_UI_SIGNET"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_UI_SIGNET=1 for the live credit quote probe")
        }
        continueAfterFailure = false

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let client = WalletClient()
        addTeardownBlock {
            try await client.stop()
            try FileManager.default.removeItem(at: fixture)
        }
        let password = Data(UUID().uuidString.utf8)

        // A sub-floor receive must be payable through credit, including when
        // the payer has no existing credit and needs a quoted Ark top-up.
        try await client.start(.signet(dataDir: fixture.appendingPathComponent("receiver").path))
        _ = try await client.createWallet(walletPassword: password)
        try await waitForServices(client)
        let receive = try await client.receiveLightning(
            amountSat: 10, memo: "Micro payment quote \(UUID().uuidString)"
        )
        try await client.stop()

        try await client.start(.signet(dataDir: fixture.appendingPathComponent("payer").path))
        _ = try await client.createWallet(walletPassword: password)
        try await waitForServices(client)
        let quote = try await client.prepareSend(invoice: receive.invoice)
        let credit = try XCTUnwrap(quote.creditPreview)
        XCTAssertEqual(quote.amountSat, 10)
        XCTAssertTrue(credit.mustUseCredit)
        XCTAssertEqual(credit.creditAppliedSat, 0)
        XCTAssertGreaterThanOrEqual(credit.creditShortfallSat, 10)
        XCTAssertGreaterThanOrEqual(credit.creditTopupSat, credit.creditShortfallSat)
        XCTAssertLessThanOrEqual(credit.creditTopupSat, Int64(SendCreditDefaults.maxCreditTopupSat))
        XCTAssertEqual(quote.expectedTotalOutflowSat, credit.arkFundingSat + credit.creditTopupSat)

        // Explicit opt-out must still reach the native binding.
        do {
            _ = try await client.prepareSend(
                invoice: receive.invoice, maxCreditSat: 0, maxCreditTopupSat: 0
            )
            XCTFail("A sub-floor payment must require credit authorization")
        } catch let error as WalletError {
            // With credit disabled, this invoice falls back to the regular
            // swap path and is rejected by the operator's minimum amount.
            XCTAssertTrue(error.message.lowercased().contains("minimum"), error.message)
        }
        let balance = try await client.balance()
        XCTAssertEqual(balance.confirmedSat, 0)
        XCTAssertEqual(balance.creditAvailableSat, 0)
        print("Micro payment quote: \(quote.amountSat) sat; top-up \(credit.creditTopupSat) sat; no dispatch")
    }

    private func waitForServices(_ client: WalletClient) async throws {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let info = try await client.getInfo()
            if info.walletReady && info.serverConnected { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTFail("Wallet services did not become ready")
        throw NSError(domain: "SDKIntegrationTests", code: 1)
    }
}
