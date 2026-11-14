import Foundation

/// Serializes native work without discarding another callback's OS opportunity.
/// Expiration cancels a waiter, never the owner whose native call is still joining.
@MainActor
final class BackgroundWorkAdmission {
    private struct Waiter {
        let id: String
        let lease: ReceiptFetchLease
        let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var activeWindowID: String?
    private var waiters: [Waiter] = []

    func run<Value>(id: String, lease: ReceiptFetchLease,
                    operation: () async throws -> Value) async rethrows -> Value? {
        guard await acquire(id: id, lease: lease) else { return nil }
        defer { release(id: id) }
        guard !lease.expired, !Task.isCancelled else { return nil }
        return try await operation()
    }

    /// Optional receipt proof must not delay another event's generic banner.
    func runIfAvailable<Value>(id: String, lease: ReceiptFetchLease,
                               operation: () async throws -> Value) async rethrows -> Value? {
        guard activeWindowID == nil, !lease.expired, !Task.isCancelled else { return nil }
        activeWindowID = id
        defer { release(id: id) }
        return try await operation()
    }

    func cancelPending(_ id: String) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func acquire(id: String, lease: ReceiptFetchLease) async -> Bool {
        guard !lease.expired, !Task.isCancelled else { return false }
        if activeWindowID == nil {
            activeWindowID = id
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !lease.expired, !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, lease: lease, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPending(id) }
        }
    }

    private func release(id: String) {
        guard activeWindowID == id else { return }
        activeWindowID = nil
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if next.lease.expired {
                next.continuation.resume(returning: false)
                continue
            }
            activeWindowID = next.id
            next.continuation.resume(returning: true)
            break
        }
    }
}
