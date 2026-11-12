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
        var receiverConfig = WalletConfig.signet(dataDir: fixture.appendingPathComponent("receiver").path)
        receiverConfig.durableRoundRuntime = true
        try await client.start(receiverConfig)
        _ = try await client.createWallet(walletPassword: password)
        try await waitForServices(client)
        // A fresh wallet must decode the native recovery result as an empty
        // list, rather than fail on Go's nil-slice JSON representation.
        let inventory = try await client.recoveryInventory()
        XCTAssertTrue(inventory.vtxos.isEmpty)
        XCTAssertEqual(inventory.total, 0)
        let receive = try await client.receiveLightning(
            amountSat: 10, memo: "Micro payment quote \(UUID().uuidString)"
        )
        try await client.stop()

        // Reopen the same durable wallet and exercise the ordinary receive
        // path too. Restart must retain the mailbox identity and still start
        // every service needed to create a fresh invoice.
        try await client.start(receiverConfig)
        _ = try await client.unlockWallet(walletPassword: password)
        try await waitForServices(client)
        let ordinaryReceive = try await client.receiveLightning(
            amountSat: 5_000, memo: "Durable restart \(UUID().uuidString)"
        )
        XCTAssertTrue(ordinaryReceive.invoice.lowercased().hasPrefix("lntbs"))
        try await client.stop()

        var payerConfig = WalletConfig.signet(dataDir: fixture.appendingPathComponent("payer").path)
        payerConfig.durableRoundRuntime = true
        try await client.start(payerConfig)
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
