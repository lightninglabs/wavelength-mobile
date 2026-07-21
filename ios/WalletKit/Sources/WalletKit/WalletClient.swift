import Foundation

// The gomobile-generated bindings. The framework name comes from the
// `make mobile-ios` output (Wavewalletdk.xcframework), and the symbol prefix is the
// Go package name, "Mobile" (e.g. MobileStart, MobileGetInfo, MobileSubscribe).
// All generated-symbol use is confined to the `Bindings` enum below, so if the
// gomobile prefix changes it is a one-place edit.
#if canImport(Wavewalletdk)
import Wavewalletdk
#endif

/// Thrown when an embedded-wallet call fails. Wraps the Go-side error.
public struct WalletError: Error, Sendable {
    public let message: String
    init(_ error: Error) { self.message = (error as NSError).localizedDescription }
    init(message: String) { self.message = message }
}

/// An idiomatic Swift facade over the gomobile bindings.
///
/// Every call is `async throws`, runs the blocking binding off the main actor,
/// and returns a typed model. The wallet activity stream is an
/// `AsyncThrowingStream` that closes its subscription when the consuming task
/// ends. One embedded daemon runs per process, so a single shared instance is
/// enough for the whole app.
public actor WalletClient {
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init() {
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    /// Whether the embedded daemon is currently running.
    public var isRunning: Bool { Bindings.isRunning() }

    /// Boot the embedded daemon and wait until its gRPC channel is serving.
    public func start(_ config: WalletConfig) async throws {
        let json = String(decoding: try encoder.encode(config), as: UTF8.self)
        try await bg { try Bindings.start(json) }
    }

    /// Tear the daemon down. Idempotent.
    public func stop() async throws {
        try await bg { try Bindings.stop() }
    }

    /// Daemon readiness snapshot.
    public func getInfo() async throws -> Info {
        try decode(await bg { try Bindings.getInfo() })
    }

    /// Wallet readiness, balance, and pending-activity count.
    public func status() async throws -> Status {
        try decode(await bg { try Bindings.status() })
    }

    /// Wallet balance summary.
    public func balance() async throws -> Balance {
        try decode(await bg { try Bindings.balance() })
    }

    /// Create or import the wallet. An empty mnemonic generates a fresh seed.
    public func createWallet(
        walletPassword: Data,
        mnemonic: [String] = []
    ) async throws -> CreateWalletResult {
        let req = CreateWalletReq(
            mnemonic: mnemonic,
            walletPassword: walletPassword.base64EncodedString()
        )
        let body = try encoder.encode(req)
        return try decode(await bg { try Bindings.createWallet(body) })
    }

    /// Unlock an existing wallet.
    public func unlockWallet(walletPassword: Data) async throws -> UnlockWalletResult {
        let req = UnlockWalletReq(walletPassword: walletPassword.base64EncodedString())
        let body = try encoder.encode(req)
        return try decode(await bg { try Bindings.unlockWallet(body) })
    }

    /// Open a Lightning invoice to receive `amountSat` into the wallet. Share
    /// the returned invoice with the payer; the matching entry shows up on the
    /// activity stream as it is paid.
    public func receiveLightning(amountSat: Int64, memo: String = "") async throws -> ReceiveResult {
        let body = try encoder.encode(ReceiveReq(amountSat: amountSat, memo: memo))
        return try decode(await bg { try Bindings.receive(body) })
    }

    /// Allocate a fresh on-chain boarding address to deposit into.
    public func newDepositAddress(amountSatHint: Int64 = 0) async throws -> DepositResult {
        let body = try encoder.encode(DepositReq(amountSatHint: amountSatHint))
        return try decode(await bg { try Bindings.deposit(body) })
    }

    /// Quote an outbound payment without moving funds. Set exactly one of
    /// `invoice` or `onchainAddress`. The result carries a single-use intent id
    /// to pass to `send(_:)`. `sweepAll` drains every VTXO to the address.
    public func prepareSend(
        invoice: String? = nil,
        onchainAddress: String? = nil,
        amountSat: Int64 = 0,
        note: String = "",
        maxFeeSat: Int64 = 0,
        sweepAll: Bool = false
    ) async throws -> PrepareSendResult {
        let req = PrepareSendReq(
            invoice: invoice, onchainAddress: onchainAddress, amountSat: amountSat,
            note: note, maxFeeSat: maxFeeSat, sweepAll: sweepAll
        )
        let body = try encoder.encode(req)
        return try decode(await bg { try Bindings.prepareSend(body) })
    }

    /// Dispatch a prepared send, consuming the single-use intent id.
    public func send(_ sendIntentID: String) async throws -> SendResult {
        let body = try encoder.encode(SendPreparedReq(sendIntentID: sendIntentID))
        return try decode(await bg { try Bindings.sendPrepared(body) })
    }

    /// Pay a Lightning invoice in one call, skipping the explicit quote step.
    /// Use `prepareSend` + `send` when you want to show the fee before paying.
    public func payInvoice(_ invoice: String, maxFeeSat: Int64 = 0) async throws -> SendResult {
        let quote = try await prepareSend(invoice: invoice, maxFeeSat: maxFeeSat)
        return try await send(quote.sendIntentID)
    }

    /// List a unified wallet view: the merged activity history, the live VTXO
    /// inventory, or the on-chain transaction history. Read the `ListResult`
    /// property named by its `view`. `kinds`, `pendingOnly`, `limit`, and
    /// `offset` apply to the activity view.
    public func list(
        view: ListView = .activity,
        kinds: [String] = [],
        pendingOnly: Bool = false,
        limit: Int64 = 0,
        offset: Int64 = 0
    ) async throws -> ListResult {
        let req = ListReq(
            view: view.rawValue, pendingOnly: pendingOnly,
            kinds: kinds, limit: limit, offset: offset
        )
        let body = try encoder.encode(req)
        return try decode(await bg { try Bindings.list(body) })
    }

    /// Exit a VTXO back to the chain. The daemon queues a cooperative leave by
    /// default, paying out to `destination` (or a fresh backing-wallet address
    /// when empty). To bypass cooperation and start a unilateral unroll, pass
    /// `forceUnrollAck` = "I_KNOW_WHAT_I_AM_DOING"; it cannot be combined with
    /// `destination`. Track progress with `exitStatus` or the activity stream.
    public func exit(
        outpoint: String,
        destination: String = "",
        forceUnrollAck: String = ""
    ) async throws -> ExitResult {
        let req = ExitReq(
            outpoint: outpoint, destination: destination,
            forceUnrollAck: forceUnrollAck
        )
        let body = try encoder.encode(req)
        return try decode(await bg { try Bindings.exit(body) })
    }

    /// Query the phase of an exit job for a VTXO outpoint.
    public func exitStatus(outpoint: String) async throws -> ExitStatusResult {
        let body = try encoder.encode(ExitStatusReq(outpoint: outpoint))
        return try decode(await bg { try Bindings.exitStatus(body) })
    }

    /// Stream only incoming payments (receives and deposits) as they arrive and
    /// settle. A convenience over `activity` filtered to the credit kinds: watch
    /// for an `Entry` whose status becomes "complete".
    public nonisolated func incomingPayments(
        includeExisting: Bool = false
    ) -> AsyncThrowingStream<Entry, Error> {
        activity(includeExisting: includeExisting, kinds: ["receive", "deposit"])
    }

    /// Stream wallet activity. The stream finishes on a clean end-of-stream and
    /// throws `WalletError` on a real error. Cancelling the consuming task
    /// closes the underlying subscription, which unblocks the pull loop.
    public nonisolated func activity(
        includeExisting: Bool = false,
        kinds: [String] = []
    ) -> AsyncThrowingStream<Entry, Error> {
        AsyncThrowingStream { continuation in
            let decoder = JSONDecoder()
            let reqData = (try? JSONEncoder().encode(
                SubscribeReq(includeExisting: includeExisting, kinds: kinds)
            )) ?? Data("{}".utf8)

            let sub: BindingsSubscription
            do {
                sub = try Bindings.subscribe(reqData)
            } catch {
                continuation.finish(throwing: WalletError(error))
                return
            }

            let task = Task.detached {
                while !Task.isCancelled {
                    let data: Data
                    do {
                        data = try sub.next()
                    } catch {
                        if Self.isEndOfStream(error) { break }
                        continuation.finish(throwing: WalletError(error))
                        return
                    }
                    if let entry = try? decoder.decode(Entry.self, from: data) {
                        continuation.yield(entry)
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                try? sub.close()
                task.cancel()
            }
        }
    }

    // MARK: - internals

    private func bg<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: WalletError(error)) }
            }
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) }
        catch { throw WalletError(error) }
    }

    private static func isEndOfStream(_ error: Error) -> Bool {
        (error as NSError).localizedDescription.lowercased().contains("eof")
    }
}

// Request bodies. Keys match the Go DTO field names (PascalCase).
private struct CreateWalletReq: Encodable {
    let mnemonic: [String]
    let walletPassword: String
    enum CodingKeys: String, CodingKey {
        case mnemonic = "Mnemonic"
        case walletPassword = "WalletPassword"
    }
}

private struct UnlockWalletReq: Encodable {
    let walletPassword: String
    enum CodingKeys: String, CodingKey {
        case walletPassword = "WalletPassword"
    }
}

private struct SubscribeReq: Encodable {
    let includeExisting: Bool
    let kinds: [String]
    enum CodingKeys: String, CodingKey {
        case includeExisting = "IncludeExisting"
        case kinds = "Kinds"
    }
}

private struct ReceiveReq: Encodable {
    let amountSat: Int64
    let memo: String
    enum CodingKeys: String, CodingKey {
        case amountSat = "AmountSat"
        case memo = "Memo"
    }
}

private struct DepositReq: Encodable {
    let amountSatHint: Int64
    enum CodingKeys: String, CodingKey {
        case amountSatHint = "AmountSatHint"
    }
}

private struct PrepareSendReq: Encodable {
    let invoice: String?
    let onchainAddress: String?
    let amountSat: Int64
    let note: String
    let maxFeeSat: Int64
    let sweepAll: Bool
    enum CodingKeys: String, CodingKey {
        case invoice = "Invoice"
        case onchainAddress = "OnchainAddress"
        case amountSat = "AmountSat"
        case note = "Note"
        case maxFeeSat = "MaxFeeSat"
        case sweepAll = "SweepAll"
    }
}

private struct SendPreparedReq: Encodable {
    let sendIntentID: String
    enum CodingKeys: String, CodingKey {
        case sendIntentID = "SendIntentID"
    }
}

private struct ListReq: Encodable {
    let view: String
    let pendingOnly: Bool
    let kinds: [String]
    let limit: Int64
    let offset: Int64
    enum CodingKeys: String, CodingKey {
        case view = "View"
        case pendingOnly = "PendingOnly"
        case kinds = "Kinds"
        case limit = "Limit"
        case offset = "Offset"
    }
}

private struct ExitReq: Encodable {
    let outpoint: String
    let destination: String
    let forceUnrollAck: String
    enum CodingKeys: String, CodingKey {
        case outpoint = "Outpoint"
        case destination = "Destination"
        case forceUnrollAck = "ForceUnrollAck"
    }
}

private struct ExitStatusReq: Encodable {
    let outpoint: String
    enum CodingKeys: String, CodingKey {
        case outpoint = "Outpoint"
    }
}
