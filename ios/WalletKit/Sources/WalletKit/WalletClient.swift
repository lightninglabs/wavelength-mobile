import Foundation

// The gomobile-generated bindings. The framework name comes from the
// `make mobile-ios` output (Walletdk.xcframework), and the symbol prefix is the
// Go package name, "Mobile" (e.g. MobileStart, MobileGetInfo, MobileSubscribe).
// All generated-symbol use is confined to the `Bindings` enum below, so if the
// gomobile prefix changes it is a one-place edit.
#if canImport(Walletdk)
import Walletdk
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
