package engineering.lightning.wavelength

import engineering.lightning.wavelength.background.*
import engineering.lightning.wavewalletdk.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class BackgroundTests {
  @Test fun cancelledWorkerRetainsNativeOwnerUntilRealReturnAndCancelJoin() = runTest {
    val lock = Mutex(); val returned = CompletableDeferred<Unit>(); val cancelReturned = CompletableDeferred<Unit>()
    var cancellations = 0; var foregroundStarted = false
    val owner = MaintenanceOwner(backgroundScope,lock) { cancellations++; cancelReturned.await() }
    val caller = launch { owner.run { returned.await(); BackgroundOutcome("Returned") } }
    runCurrent(); assertTrue(lock.isLocked)
    caller.cancel();runCurrent();assertEquals(1,cancellations)
    val foreground = launch { lock.withLock { foregroundStarted = true } }
    returned.complete(Unit);runCurrent();assertFalse(foregroundStarted);assertFalse(caller.isCompleted)
    cancelReturned.complete(Unit);runCurrent();assertTrue(foregroundStarted);assertTrue(caller.isCompleted)
    foreground.join()
  }
  @Test fun deadlineAndForegroundInterruptSignalOneExactWindowWithoutReleasingOwner() = runTest {
    val lock = Mutex();val returned = CompletableDeferred<Unit>();val ids = mutableListOf<String>()
    val owner = MaintenanceOwner(backgroundScope,lock,100) { ids += it.id }
    val caller = async { owner.run { returned.await(); BackgroundOutcome("Returned") } }
    runCurrent(); val original = owner.active!!.id
    advanceTimeBy(101);runCurrent();owner.interrupt();runCurrent()
    assertEquals(listOf(original),ids);assertTrue(lock.isLocked);assertTrue(owner.active!!.expired)
    assertEquals(BackgroundCancellation.DEADLINE,owner.active!!.cancellationReason)
    returned.complete(Unit);runCurrent();caller.await();assertFalse(lock.isLocked);assertNull(owner.active)
  }
  @Test fun defaultFallbackAllowsWorkPastOldCutoffsAndJoinsCancellation() = runTest {
    val lock = Mutex(); val returned = CompletableDeferred<Unit>(); val cancelReturned = CompletableDeferred<Unit>()
    var cancellations = 0
    val owner = MaintenanceOwner(backgroundScope,lock) { cancellations++; cancelReturned.await() }
    val caller = async { owner.run { returned.await(); BackgroundOutcome("Returned") } }
    runCurrent()
    advanceTimeBy(20_001); runCurrent()
    assertEquals(0,cancellations); assertFalse(owner.active!!.expired)
    advanceTimeBy(7_999); runCurrent()
    assertEquals(1,cancellations); assertTrue(lock.isLocked)
    assertEquals(BackgroundCancellation.DEADLINE,owner.active!!.cancellationReason)
    returned.complete(Unit); runCurrent(); assertFalse(caller.isCompleted)
    cancelReturned.complete(Unit); runCurrent(); caller.await()
    assertFalse(lock.isLocked); assertNull(owner.active)
  }
  @Test fun receiptRequiresCurrentConsentOriginalPrincipalAndCompleteSourceProof() {
    val consent = ReceiptConsent("epoch",100,"owner","connection",true)
    val enrollment = EnrolledReceipt("signet",consent,ReceiptReference("credit_receive","id"),"canonical",999,101)
    val proof = LightningReceipt(enrollment.reference,"canonical","complete",999,101)
    assertTrue(receiptMatches(enrollment,consent,proof))
    assertFalse(receiptMatches(enrollment,consent.copy(epoch="new"),proof))
    assertFalse(receiptMatches(enrollment,consent,proof.copy(amountSat=1000)))
    assertFalse(receiptMatches(enrollment,consent,proof.copy(createdAtUnix=100)))
    assertFalse(receiptMatches(enrollment,consent,proof.copy(state="pending")))
    assertFalse(receiptMatches(enrollment.copy(claimed=true),consent,proof))
    assertFalse(receiptMatches(enrollment,null,proof))
    assertFalse(receiptMatches(enrollment,consent,proof.copy(canonicalId="other")))
  }
  @Test fun relayRouteMustMatchLocalConsentNetworkConnectionIdentityAndLifetime() {
    val consent = ReceiptConsent("epoch",100,"owner","connection")
    val route = RelayRoute("route","signet","owner","connection",200)
    assertTrue(routeMatches(route,"signet",null,"connection",consent,101))
    assertFalse(routeMatches(route,"mainnet",null,"connection",consent,101))
    assertFalse(routeMatches(route,"signet","other","connection",consent,101))
    assertFalse(routeMatches(route,"signet",null,"override",consent,101))
    assertFalse(routeMatches(route,"signet",null,"connection",consent,200))
    assertFalse(routeMatches(route,"signet",null,"connection",null,101))
  }
  @Test fun remoteHintCannotSupplyAmountEndpointOrInvoiceAuthority() {
    val good = mapOf("version" to "1","route_id" to "route-1","kind" to "payment_activity","event_id" to "ab".repeat(32))
    assertNotNull(PushHint.parse(good))
    assertNull(PushHint.parse(good + ("version" to "true")))
    assertNull(PushHint.parse(good + ("route_id" to "https://attacker")))
    assertNull(PushHint.parse(good + ("kind" to "send")))
    assertNull(PushHint.parse(good + ("event_id" to "AB".repeat(32))))
    assertEquals(PushHint.parse(good),PushHint.parse(good + mapOf("amount" to "999999","endpoint" to "https://attacker","invoice" to "fake")))
  }
}
