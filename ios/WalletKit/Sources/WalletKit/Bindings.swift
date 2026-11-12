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
// When Wavewalletdk.xcframework is absent, the #else stubs keep the package
// compiling and throw at runtime. Build it with `make mobile-ios`; see
// ios/README.md.

#if canImport(Wavewalletdk)
import Wavewalletdk

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

    static func setNotificationSubscription(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileSetNotificationSubscription(req, &err), err)
    }

    static func setNotificationFeedGrant(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileSetNotificationFeedGrant(req, &err), err)
    }

    static func processNext(_ id: String, _ seconds: Int64) throws -> Data {
        var err: NSError?
        return try unwrap(MobileProcessNext(id, seconds, &err), err)
    }

    static func setHostForeground(_ foreground: Bool) throws {
        var err: NSError?
        let ok = MobileSetHostForeground(foreground, &err)
        if let err { throw WalletError(err) }
        if !ok { throw WalletError(message: "MobileSetHostForeground returned false") }
    }

    static func runReceiptWindow(_ req: Data, _ seconds: Int64) throws -> Data {
        var err: NSError?
        return try unwrap(MobileRunReceiptWindow(req, seconds, &err), err)
    }

    static func runMaintenanceWindow(_ id: String, _ seconds: Int64) throws -> Data {
        var err: NSError?
        return try unwrap(MobileRunMaintenanceWindow(id, seconds, &err), err)
    }

    static func cancelReceiptWindow(_ id: String) throws {
        var err: NSError?
        let ok = MobileCancelReceiptWindow(id, &err)
        if let err { throw WalletError(err) }
        if !ok { throw WalletError(message: "MobileCancelReceiptWindow returned false") }
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

    static func unlockWallet(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileUnlockWallet(req, &err), err)
    }

    static func receive(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileReceive(req, &err), err)
    }

    static func deposit(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileDeposit(req, &err), err)
    }

    static func prepareSend(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobilePrepareSend(req, &err), err)
    }

    static func sendPrepared(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileSendPrepared(req, &err), err)
    }

    static func list(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileList(req, &err), err)
    }

    static func exit(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileExit(req, &err), err)
    }

    static func estimateExitFee(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileEstimateExitFee(req, &err), err)
    }

    static func exitBatch(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileExitBatch(req, &err), err)
    }

    static func diagnosticRead(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileDiagnosticRead(req, &err), err)
    }

    static func diagnosticLogs() throws -> Data {
        var err: NSError?
        return try unwrap(MobileDiagnosticLogs(&err), err)
    }

    static func exitStatus(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileExitStatus(req, &err), err)
    }

    static func recoveryInventory() throws -> Data {
        var err: NSError?
        return try unwrap(MobileRecoveryInventory(&err), err)
    }

    static func observeRefresh(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileObserveRefresh(req, &err), err)
    }

    static func refresh(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileRefresh(req, &err), err)
    }

    static func getExitPlan(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileGetExitPlan(req, &err), err)
    }

    static func exitSummary(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileExitSummary(req, &err), err)
    }

    static func sweepWallet(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileSweepWallet(req, &err), err)
    }

    static func exportExits(_ req: Data) throws -> Data {
        var err: NSError?
        return try unwrap(MobileExportExits(req, &err), err)
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
    func next() throws -> Data { throw WalletError(message: "Wavewalletdk.xcframework not linked") }
    func close() throws {}
}

enum Bindings {
    private static func missing() -> Error { WalletError(message: "Wavewalletdk.xcframework not linked") }
    static func isRunning() -> Bool { false }
    static func start(_ cfg: String) throws { throw missing() }
    static func stop() throws { throw missing() }
    static func setNotificationSubscription(_ req: Data) throws -> Data { throw missing() }
    static func setNotificationFeedGrant(_ req: Data) throws -> Data { throw missing() }
    static func processNext(_ id: String, _ seconds: Int64) throws -> Data { throw missing() }
    static func setHostForeground(_ foreground: Bool) throws { throw missing() }
    static func runReceiptWindow(_ req: Data, _ seconds: Int64) throws -> Data { throw missing() }
    static func runMaintenanceWindow(_ id: String, _ seconds: Int64) throws -> Data { throw missing() }
    static func cancelReceiptWindow(_ id: String) throws { throw missing() }
    static func getInfo() throws -> Data { throw missing() }
    static func status() throws -> Data { throw missing() }
    static func balance() throws -> Data { throw missing() }
    static func createWallet(_ req: Data) throws -> Data { throw missing() }
    static func unlockWallet(_ req: Data) throws -> Data { throw missing() }
    static func receive(_ req: Data) throws -> Data { throw missing() }
    static func deposit(_ req: Data) throws -> Data { throw missing() }
    static func prepareSend(_ req: Data) throws -> Data { throw missing() }
    static func sendPrepared(_ req: Data) throws -> Data { throw missing() }
    static func list(_ req: Data) throws -> Data { throw missing() }
    static func exit(_ req: Data) throws -> Data { throw missing() }
    static func exitBatch(_ req: Data) throws -> Data { throw missing() }
    static func estimateExitFee(_ req: Data) throws -> Data { throw missing() }
    static func diagnosticRead(_ req: Data) throws -> Data { throw missing() }
    static func diagnosticLogs() throws -> Data { throw missing() }
    static func exitStatus(_ req: Data) throws -> Data { throw missing() }
    static func recoveryInventory() throws -> Data { throw missing() }
    static func observeRefresh(_ req: Data) throws -> Data { throw missing() }
    static func refresh(_ req: Data) throws -> Data { throw missing() }
    static func getExitPlan(_ req: Data) throws -> Data { throw missing() }
    static func exitSummary(_ req: Data) throws -> Data { throw missing() }
    static func sweepWallet(_ req: Data) throws -> Data { throw missing() }
    static func exportExits(_ req: Data) throws -> Data { throw missing() }
    static func subscribe(_ req: Data) throws -> BindingsSubscription { throw missing() }
}

#endif
