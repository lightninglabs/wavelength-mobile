import SQLite3
import XCTest
import WalletKit

/// A disposable, unfunded wallet exercises the published storage boundary.
/// This never opens the sample app's wallet or writes to its Keychain.
final class StorageIntegrationTests: XCTestCase {
    func testManagedStorageCoexistsWithHostDatabaseAndRelocates() async throws {
        guard ProcessInfo.processInfo.environment["WAVELENGTH_STORAGE_SIGNET"] == "1" else {
            throw XCTSkip("Set WAVELENGTH_STORAGE_SIGNET=1 for the live storage probe")
        }
        continueAfterFailure = false

        let files = FileManager.default
        let fixture = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = fixture.appendingPathComponent("managed")
        let relocated = fixture.appendingPathComponent("relocated")
        try files.createDirectory(at: fixture, withIntermediateDirectories: true)

        let client = WalletClient()
        addTeardownBlock {
            // Remove only this disposable fixture, and only after Stop succeeds.
            try await client.stop()
            try files.removeItem(at: fixture)
        }

        let host = try HostDatabase(url: fixture.appendingPathComponent("app.sqlite"))
        defer { host.close() }
        try host.execute("CREATE TABLE business_state (value INTEGER NOT NULL)")
        try host.execute("INSERT INTO business_state VALUES (1)")

        // The app can hold its own write transaction while the wallet opens,
        // creates keys, and persists a receive in separate managed databases.
        try host.execute("BEGIN IMMEDIATE")
        try host.execute("UPDATE business_state SET value = 2")
        let password = Data(UUID().uuidString.utf8)
        try await client.start(.signet(dataDir: original.path))
        let initial = try await client.getInfo()
        XCTAssertEqual(initial.walletState, .none)
        _ = try await client.createWallet(walletPassword: password)
        let before = try await waitForServices(client)
        XCTAssertFalse(before.identityPubKey.isEmpty)
        let receive = try await client.receiveLightning(
            amountSat: 50_000, memo: "Storage probe \(UUID().uuidString)"
        )
        XCTAssertFalse(receive.entry.id.isEmpty)
        XCTAssertTrue(receive.invoice.lowercased().hasPrefix("lntb"))
        try host.execute("COMMIT")

        // Moving the entire closed tree preserves every store and sidecar.
        // This is deliberately neither a live backup nor a second signer.
        let stopStarted = Date()
        try await client.stop()
        let stopDuration = Date().timeIntervalSince(stopStarted)
        let running = await client.isRunning
        XCTAssertFalse(running)
        for file in ["waved.db", "swaps.db", "wallet.db"] {
            XCTAssertTrue(files.fileExists(atPath:
                original.appendingPathComponent("data/signet/\(file)").path
            ), "Missing managed store: \(file)")
        }
        try files.moveItem(at: original, to: relocated)

        try host.execute("BEGIN IMMEDIATE")
        let reopenStarted = Date()
        try await client.start(.signet(dataDir: relocated.path))
        let locked = try await client.getInfo()
        XCTAssertEqual(locked.walletState, .locked)
        // There is no Create call on reopen: a lost wallet must fail this probe.
        _ = try await client.unlockWallet(walletPassword: password)
        let after = try await waitForServices(client)
        let reopenDuration = Date().timeIntervalSince(reopenStarted)
        XCTAssertEqual(after.identityPubKey, before.identityPubKey)
        let history = try await client.list()
        let entries = try XCTUnwrap(history.activity).entries
            .filter { $0.id == receive.entry.id }
        XCTAssertEqual(entries.count, 1)
        let recovered = try XCTUnwrap(entries.first)
        XCTAssertEqual(recovered.request?.lightningInvoice, receive.invoice)
        XCTAssertEqual(recovered.amountSat, receive.entry.amountSat)
        XCTAssertEqual(try host.value(), 2)
        try host.execute("COMMIT")
        try await client.stop()
        XCTAssertFalse(files.fileExists(atPath: original.path),
                       "Reopen unexpectedly recreated the original storage root")

        // Timings describe this idle Simulator run, not a background deadline.
        print(String(format: "Storage probe: stop %.3fs; reopen/unlock/ready %.3fs",
                     stopDuration, reopenDuration))
    }

    private func waitForServices(_ client: WalletClient) async throws -> Info {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let info = try await client.getInfo()
            // WalletReady covers the signer; mailbox/indexer setup follows it.
            // Do not use a state-creating Receive call as a readiness probe.
            if info.walletReady && info.serverConnected { return info }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw NSError(domain: "StorageIntegrationTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Wallet readiness timed out"])
    }
}

/// Represents the host's unrelated database, never a Wavelength store adapter.
private final class HostDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let result = sqlite3_open(url.path, &handle)
        guard result == SQLITE_OK else {
            close()
            throw NSError(domain: "StorageProbeSQLite", code: Int(result))
        }
    }

    func execute(_ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "StorageProbeSQLite", code: Int(result))
        }
    }

    func value() throws -> Int32 {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            handle, "SELECT value FROM business_state", -1, &statement, nil
        )
        defer { sqlite3_finalize(statement) }
        guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "StorageProbeSQLite", code: Int(sqlite3_errcode(handle)))
        }
        return sqlite3_column_int(statement, 0)
    }

    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }
}
