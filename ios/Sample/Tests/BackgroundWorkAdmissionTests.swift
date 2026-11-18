import XCTest
@testable import Wavelength

@MainActor
final class BackgroundWorkAdmissionTests: XCTestCase {
    func testCompletedReceiptHandsOffCriticalWakeWithoutAssumingItPumped() async {
        let admission = BackgroundWorkAdmission()
        let receiptStarted = expectation(description: "receipt source read")
        let criticalStarted = expectation(description: "critical callback")
        var sourceRead: CheckedContinuation<Void, Never>?
        var pumps = 0
        var criticalFinished = false
        var simultaneousOwners = 0
        var maxOwners = 0

        let receipt = Task {
            await admission.run(id: "receipt", lease: ReceiptFetchLease { _ in }) {
                simultaneousOwners += 1
                maxOwners = max(maxOwners, simultaneousOwners)
                receiptStarted.fulfill()
                await withCheckedContinuation { sourceRead = $0 }
                simultaneousOwners -= 1
                // A canonical receipt can already be complete: no mailbox pull.
                return "complete"
            }
        }
        await fulfillment(of: [receiptStarted], timeout: 2)
        let critical = Task {
            criticalStarted.fulfill()
            let value = await admission.run(id: "quote", lease: ReceiptFetchLease { _ in }) {
                simultaneousOwners += 1
                maxOwners = max(maxOwners, simultaneousOwners)
                pumps += 1
                simultaneousOwners -= 1
                return true
            }
            criticalFinished = true
            return value
        }
        await fulfillment(of: [criticalStarted], timeout: 2)
        XCTAssertEqual(admission.activeWindowID, "receipt")
        XCTAssertEqual(pumps, 0)
        XCTAssertFalse(criticalFinished, "A second wake retains its own opportunity")
        sourceRead?.resume()
        let receiptResult = await receipt.value
        let criticalResult = await critical.value
        XCTAssertEqual(receiptResult, "complete")
        XCTAssertEqual(criticalResult, true)
        XCTAssertEqual(pumps, 1)
        XCTAssertEqual(maxOwners, 1)
        XCTAssertNil(admission.activeWindowID)
    }

    func testExpiryCancelsOnlyTheWaitingCallbackAndJoinsOwnerBeforeHandoff() async {
        let admission = BackgroundWorkAdmission()
        let ownerLease = ReceiptFetchLease { _ in }
        let waiterLease = ReceiptFetchLease { _ in }
        let started = expectation(description: "native owner")
        let waiting = expectation(description: "queued callback")
        var finalAccess: CheckedContinuation<Void, Never>?
        var expiredWork = false
        let owner = Task {
            await admission.run(id: "owner", lease: ownerLease) {
                started.fulfill()
                await withCheckedContinuation { finalAccess = $0 }
                return true
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let expired = Task {
            await admission.run(id: "expired", lease: waiterLease, onWait: { blocker in
                XCTAssertEqual(blocker, "owner")
                waiting.fulfill()
            }) {
                expiredWork = true
                return true
            }
        }
        await fulfillment(of: [waiting], timeout: 2)
        waiterLease.expire()
        admission.cancelPending("expired")
        let expiredResult = await expired.value
        XCTAssertNil(expiredResult)
        XCTAssertFalse(expiredWork)
        ownerLease.expire()
        admission.cancelPending("owner")
        XCTAssertEqual(admission.activeWindowID, "owner", "OS completion never releases final native access")
        let next = Task {
            await admission.run(id: "next", lease: ReceiptFetchLease { _ in }) { true }
        }
        finalAccess?.resume()
        _ = await owner.value
        let nextResult = await next.value
        XCTAssertEqual(nextResult, true)
        XCTAssertNil(admission.activeWindowID)
    }

    func testCanceledWaiterAndThrowingOwnerCannotStrandTheNextWake() async {
        enum Failure: Error { case native }
        let admission = BackgroundWorkAdmission()
        let started = expectation(description: "native owner")
        let waiting = expectation(description: "cancelable waiter")
        var native: CheckedContinuation<Void, Never>?
        let owner = Task {
            try await admission.run(id: "owner", lease: ReceiptFetchLease { _ in }) {
                started.fulfill()
                await withCheckedContinuation { native = $0 }
                throw Failure.native
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let canceled = Task {
            waiting.fulfill()
            return await admission.run(id: "canceled", lease: ReceiptFetchLease { _ in }) {
                XCTFail("Canceled callback started native work")
                return true
            }
        }
        await fulfillment(of: [waiting], timeout: 2)
        canceled.cancel()
        let canceledResult = await canceled.value
        XCTAssertNil(canceledResult)
        let next = Task {
            await admission.run(id: "next", lease: ReceiptFetchLease { _ in }) { true }
        }
        native?.resume()
        do { _ = try await owner.value; XCTFail("Expected native failure") }
        catch { XCTAssertTrue(error is Failure) }
        let nextResult = await next.value
        XCTAssertEqual(nextResult, true)
        XCTAssertNil(admission.activeWindowID)
    }

    func testOptionalProofDoesNotBlockIndependentPresentationWhileBusy() async {
        let admission = BackgroundWorkAdmission()
        let started = expectation(description: "native owner")
        var native: CheckedContinuation<Void, Never>?
        let owner = Task {
            await admission.run(id: "owner", lease: ReceiptFetchLease { _ in }) {
                started.fulfill()
                await withCheckedContinuation { native = $0 }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let optional = await admission.runIfAvailable(id: "optional", lease: ReceiptFetchLease { _ in }) {
            XCTFail("Optional proof overlapped the native owner")
            return true
        }
        XCTAssertNil(optional)
        XCTAssertEqual(admission.activeWindowID, "owner")
        native?.resume()
        _ = await owner.value
    }
}
