package engineering.lightning.wavelength.background

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Cancellation signals native work; only its actual return releases ownership. */
class MaintenanceOwner(private val scope: CoroutineScope, private val owner: Mutex,
  private val budgetMillis: Long = 20_000,
  private val observedRelease: (BackgroundLease) -> Unit = {}, private val cancelNative: suspend (BackgroundLease) -> Unit) {
  var active: BackgroundLease? = null; private set
  fun interrupt() { active?.let { expire(it,BackgroundCancellation.FOREGROUND) } }
  private fun expire(lease: BackgroundLease, reason: BackgroundCancellation) {
    if (lease.expire(reason)) lease.cancellation = scope.launch { runCatching { cancelNative(lease) } }
  }
  suspend fun run(block: suspend (BackgroundLease) -> BackgroundOutcome): BackgroundOutcome {
    val lease = BackgroundLease()
    // The host scope outlives an OS callback. A cancelled worker must join it.
    val work = scope.async { owner.withLock {
      if (lease.expired) return@withLock BackgroundOutcome("Cancelled before admission")
      active = lease
      val timer = scope.launch { delay(budgetMillis); expire(lease,BackgroundCancellation.DEADLINE) }
      try { block(lease) }
      finally { timer.cancel(); lease.cancellation?.join(); runCatching { observedRelease(lease) }; active = null }
    } }
    try { return work.await() }
    catch (error: CancellationException) {
      withContext(NonCancellable) { expire(lease,BackgroundCancellation.WORKER); work.join() }
      throw error
    }
  }
}
