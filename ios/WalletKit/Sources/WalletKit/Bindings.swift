import Foundation

// Bindings is the single bridge to the gomobile-generated symbols. gomobile
// emits free functions prefixed with the Go package name ("Mobile"), e.g.
// MobileStart, MobileGetInfo, MobileSubscribe, and a MobileSubscription class.
// Confining every generated-symbol reference here means a change to the gomobile
// prefix (the `make mobile-ios` `-prefix` flag) is a one-file edit, and the rest
// of WalletKit stays prefix-agnostic.
//
// When the Walletdk.xcframework is absent (e.g. building docs on a machine
// without the bindings), the stubs below keep the package compiling and throw at
// runtime. Build the framework with `make mobile-ios` in darepo-client and add
// it to the WalletKit target; see ios/README.md.

#if canImport(Walletdk)
import Walletdk

/// The generated subscription handle (`MobileSubscription`).
typealias BindingsSubscription = MobileSubscription

enum Bindings {
    static func isRunning() -> Bool { MobileIsRunning() }
    static func start(_ cfg: String) throws { try MobileStart(cfg) }
    static func stop() throws { try MobileStop() }
    static func getInfo() throws -> Data { try MobileGetInfo() }
    static func status() throws -> Data { try MobileStatus() }
    static func balance() throws -> Data { try MobileBalance() }
    static func createWallet(_ req: Data) throws -> Data { try MobileCreateWallet(req) }
    static func subscribe(_ req: Data) throws -> BindingsSubscription {
        var sub: MobileSubscription?
        // gomobile maps (T, error) to a Swift throwing call returning T.
        sub = try MobileSubscribe(req)
        guard let sub else { throw WalletError(message: "nil subscription") }
        return sub
    }
}

#else

/// Placeholder so WalletKit compiles without the bindings. Calls throw.
final class BindingsSubscription {
    func next() throws -> Data { throw WalletError(message: "Walletdk.xcframework not linked") }
    func close() {}
}

enum Bindings {
    private static func missing() -> Error { WalletError(message: "Walletdk.xcframework not linked") }
    static func isRunning() -> Bool { false }
    static func start(_ cfg: String) throws { throw missing() }
    static func stop() throws { throw missing() }
    static func getInfo() throws -> Data { throw missing() }
    static func status() throws -> Data { throw missing() }
    static func balance() throws -> Data { throw missing() }
    static func createWallet(_ req: Data) throws -> Data { throw missing() }
    static func subscribe(_ req: Data) throws -> BindingsSubscription { throw missing() }
}

#endif
