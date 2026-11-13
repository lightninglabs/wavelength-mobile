import BackgroundTasks
import Foundation

/// Schedules opportunities to apply the current tip and advance retained native
/// rounds. Registration is synchronous; execution may unlock a device-managed
/// wallet without granting access to the UI.
@MainActor
enum WalletBackgroundMaintenance {
    static let identifier = "engineering.lightning.wavelength.wallet.maintenance"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let startedAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                schedule()
                let windowID = UUID().uuidString
                if let network = WalletNotifications.shared.diagnosticNetwork {
                    DiagnosticJournal.shared.begin(id: windowID, network: network, trigger: "Scheduled refresh",
                        wake: .init(entryPoint: "BGAppRefreshTask", taskID: identifier))
                }
                let lease = ReceiptFetchLease(startedAt: startedAt) { result in
                    task.setTaskCompleted(success: result != .failed)
                }
                let expire: (String) -> Void = { reason in
                    guard !lease.finished else { return }
                    lease.expire(.failed)
                    Task { await WalletNotifications.shared.cancelReceiptRecovery(windowID, reason: reason) }
                }
                task.expirationHandler = { Task { @MainActor in expire("iOS window expired") } }
                let deadline = lease.fallback { expire("Fallback deadline reached") }
                let changed = await WalletNotifications.shared.runMaintenance(windowID: windowID, lease: lease)
                deadline.cancel()
                lease.finish(changed ? .newData : .noData)
                task.expirationHandler = nil
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // A pending request with this identifier is replaced. iOS owns timing;
        // disabled background refresh is an ordinary skipped opportunity.
        try? BGTaskScheduler.shared.submit(request)
    }
}
