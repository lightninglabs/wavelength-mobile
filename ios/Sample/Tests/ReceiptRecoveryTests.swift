import XCTest
@testable import WalletKit

final class ReceiptRecoveryTests: XCTestCase {
    private let entry: [String: Any] = [
        "ID": "entry", "Kind": "receive", "Status": "pending",
        "AmountSat": 100_000, "FeeSat": 0, "Counterparty": "", "Note": ""
    ]

    func testOptionalReceiptMetadataCannotFailCreatedInvoice() throws {
        let metadataValues: [Any] = [NSNull(), ["source": "future", "id": "future-id"],
                                     ["source": 17, "id": []], "unexpected"]
        for metadata in metadataValues {
            let raw = try JSONSerialization.data(withJSONObject: [
                "Invoice": "ln-test", "Entry": entry, "ReceiptReference": metadata
            ])
            let result = try JSONDecoder().decode(ReceiveResult.self, from: raw)
            XCTAssertEqual(result.invoice, "ln-test")
            XCTAssertEqual(result.entry.id, "entry")
            XCTAssertFalse(result.receiptReference?.isSupported ?? false)
        }
    }

    func testTypedReferenceAndHistoricalRecoveryBoundary() throws {
        let raw = try JSONSerialization.data(withJSONObject: [
            "Invoice": "ln-test", "Entry": entry,
            "ReceiptReference": ["source": "credit_receive", "id": "operation-id"]
        ])
        let result = try JSONDecoder().decode(ReceiveResult.self, from: raw)
        XCTAssertEqual(result.receiptReference?.id, "operation-id")
        XCTAssertTrue(result.receiptReference?.isSupported ?? false)
        let recovered = ReceiveResult(invoice: result.invoice, entry: result.entry)
        XCTAssertNil(recovered.receiptReference)
    }

    func testWindowWireFormatAndNumericAmount() throws {
        let reference = LightningReceiptReference(source: "lightning_swap", id: "hash")
        let request = ReceiptWindowRequest(windowID: "window", reference: reference, createdAfterUnix: 123)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(body["window_id"] as? String, "window")
        XCTAssertEqual(body["created_after_unix"] as? Int64, 123)
        let raw = Data(#"{"receipts":[{"reference":{"source":"lightning_swap","id":"hash"},"canonical_id":"entry","state":"complete","amount_sat":100000,"created_at_unix":124}],"batches":2,"needs_foreground":false,"interrupted":false,"budget_exhausted":false}"#.utf8)
        let result = try JSONDecoder().decode(ReceiptWindowResult.self, from: raw)
        XCTAssertEqual(result.receipts.first?.amountSat, 100_000)
        XCTAssertEqual(result.receipts.first?.canonicalID, "entry")
        XCTAssertFalse(result.interrupted)
        XCTAssertFalse(result.needsForeground)
    }

    func testNativeWindowAPIsRejectUnstartedRuntime() async {
        let client = WalletClient()
        do {
            try await client.setHostForeground(true)
            XCTFail("Unstarted native runtime accepted a mode change")
        } catch { XCTAssertTrue(error.localizedDescription.contains("not started")) }
        do {
            try await client.cancelReceiptWindow("window")
            XCTFail("Unstarted native runtime accepted window cancellation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("not started")) }
        do {
            _ = try await client.runMaintenanceWindow("maintenance")
            XCTFail("Unstarted native runtime accepted maintenance")
        } catch { XCTAssertTrue(error.localizedDescription.contains("not started")) }
        do {
            _ = try await client.runReceiptWindow(ReceiptWindowRequest(
                windowID: "window", reference: .init(source: "lightning_swap", id: "hash"),
                createdAfterUnix: 123
            ))
            XCTFail("Unstarted native runtime accepted a receipt window")
        } catch { XCTAssertTrue(error.localizedDescription.contains("not started")) }
    }

    func testDurableRuntimeUsesNativeConfigKey() throws {
        var config = WalletConfig.signet(dataDir: "/tmp/receipt-config")
        config.durableRoundRuntime = true
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertEqual(body["durable_round_runtime"] as? Bool, true)
    }
}
