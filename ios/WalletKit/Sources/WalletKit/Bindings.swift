import Foundation

// Bindings is the single bridge to the gomobile-generated symbols. gomobile
// emits free C functions prefixed with the Go package name ("Mobile"), e.g.
// MobileStart, MobileGetInfo, MobileSubscribe, and a MobileSubscription class.
// Confining every generated-symbol reference here means a change to the gomobile
// prefix (the `gomobile bind -prefix` flag) is a one-file edit.
//
// Note: Swift does NOT auto-translate gomobile's *free functions* into `throws`
// (that audit only applies to Objective-C methods), so each takes an explicit
// NSError out-parameter that we convert to a thrown WalletError here. The
// MobileSubscription *methods* (next/close) are ObjC methods, so those do import
// as `throws`.
//
// When Walletdk.xcframework is absent, the #else stubs keep the package
// compiling and throw at runtime. Build it with `make mobile-ios`; see
// ios/README.md.

#if canImport(Walletdk)
import Walletdk

typealias BindingsSubscription = MobileSubscription

enum Bindings {
    static func isRunning() -> Bool { MobileIsRunning() }

    static func start(_ cfg: String) throws {
        var err: NSError?
        let ok = MobileStart(cfg, &err)
        if let err { throw WalletError(err) }
        if !ok { throw WalletError(message: "MobileStart returned false") }
    }

    static func stop() throws {
        var err: NSError?
        let ok = MobileStop(&err)
        if let err { throw WalletError(err) }
        if !ok { throw WalletError(message: "MobileStop returned false") }
    }

    static func getInfo() throws -> Data {
        var err: NSError?
        return try unwrap(MobileGetInfo(&err), err)
    }

    static func status() throws -> Data {
        var err: NSError?
        return try unwrap(MobileStatus(&err), err)
    }

    static func balance() throws -> Data {
        var err: NSError?
        return try unwrap(MobileBalance(&err), err)
    }

    static func createWallet(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileCreateWallet(req, &err), err)
    }

    static func subscribe(_ req: Data) throws -> BindingsSubscription {
        var err: NSError?
        let sub = MobileSubscribe(req, &err)
        if let err { throw WalletError(err) }
        guard let sub else { throw WalletError(message: "nil subscription") }
        return sub
    }

    private static func unwrap(_ data: Data?, _ err: NSError?) throws -> Data {
        if let err { throw WalletError(err) }
        guard let data else { throw WalletError(message: "nil response") }
        return data
    }
}

#else

/// Placeholder so WalletKit compiles without the bindings. Calls throw.
final class BindingsSubscription {
    func next() throws -> Data { throw WalletError(message: "Walletdk.xcframework not linked") }
    func close() throws {}
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
