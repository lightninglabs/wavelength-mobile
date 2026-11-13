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
            Task { @MainActor in
                schedule()
                let windowID = UUID().uuidString
                if let network = WalletNotifications.shared.diagnosticNetwork {
                    DiagnosticJournal.shared.begin(id: windowID, network: network, trigger: "Scheduled refresh",
                        wake: .init(entryPoint: "BGAppRefreshTask", taskID: identifier))
                }
                let lease = ReceiptFetchLease { result in
                    task.setTaskCompleted(success: result != .failed)
                }
                let expire: () -> Void = {
                    guard !lease.finished else { return }
                    lease.expire(.failed)
                    Task { await WalletNotifications.shared.cancelReceiptRecovery(windowID) }
                }
                task.expirationHandler = { Task { @MainActor in expire() } }
                // The native budget is shorter; retain an outer completion
                // deadline when an uncooperative dependency outlives that budget.
                let deadline = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if !Task.isCancelled { expire() }
                }
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
