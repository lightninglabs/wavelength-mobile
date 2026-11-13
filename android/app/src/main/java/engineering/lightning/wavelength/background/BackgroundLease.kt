package engineering.lightning.wavelength.background

import java.util.UUID

enum class BackgroundCancellation(val label: String) { DEADLINE("Window expired"), FOREGROUND("Foreground takeover"), WORKER("Worker cancelled") }

/** Main-thread owned cancellation fence. Expiry never releases native ownership. */
class BackgroundLease(val id: String = UUID.randomUUID().toString()) {
  var cancellationReason: BackgroundCancellation? = null; private set
  val expired get() = cancellationReason != null
  var coldStarting = false
  var cancellation: kotlinx.coroutines.Job? = null
  fun expire(reason: BackgroundCancellation): Boolean { if (expired) return false; cancellationReason = reason; return true }
}
data class BackgroundOutcome(val label: String, val changed: Boolean = false)
