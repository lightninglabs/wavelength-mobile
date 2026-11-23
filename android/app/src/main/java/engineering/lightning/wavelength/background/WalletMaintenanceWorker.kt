package engineering.lightning.wavelength.background

import android.content.Context
import androidx.work.*
import engineering.lightning.wavelength.WalletApplication
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/** WorkManager owns OS scheduling; the session retains the native invocation. */
class WalletMaintenanceWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context,parameters) {
  override suspend fun doWork(): Result {
    val wallet = (applicationContext as WalletApplication).wallet
    if (inputData.getString("trigger") == "Scheduled") wallet.relay.schedule()
    val routeId = inputData.getString("route")
    val trigger = inputData.getString("trigger") ?: "Scheduled"
    val wake = BackgroundWakeContext(
      if (trigger == "Scheduled") "WorkManager periodic" else "WorkManager one-time",
      id.toString(), runAttemptCount
    )
    val route = routeId?.let { id -> withContext(Dispatchers.Main.immediate) {
      RelayPushRegistry(applicationContext).resolve(id,wallet)
    } }
    if (routeId != null && route == null) return Result.success()
    val producer = if (route != null && trigger == "Push wake") BackgroundProducerWake.parse(
      inputData.getString("wake_reason"), inputData.getString("wake_deadline_unix")
    ) else null
    wallet.runBackground(trigger,route?.network,route?.identity,wake.copy(producer = producer))
    // Another periodic/remote opportunity may retry existing native work. This
    // worker never retries a payment create/send or infers round completion.
    return Result.success()
  }
}

object WalletWork {
  const val PERIODIC = "wavelength.maintenance.v1"
  fun schedule(context: Context) {
    val request = PeriodicWorkRequestBuilder<WalletMaintenanceWorker>(15,TimeUnit.MINUTES)
      .setInitialDelay(15,TimeUnit.MINUTES)
      .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
      .setInputData(workDataOf("trigger" to "Scheduled")).build()
    WorkManager.getInstance(context).enqueueUniquePeriodicWork(PERIODIC,ExistingPeriodicWorkPolicy.KEEP,request)
  }
  fun opportunity(context: Context, trigger: String, route: String? = null, delaySeconds: Long = 0,
    producer: BackgroundProducerWake? = null) {
    val request = OneTimeWorkRequestBuilder<WalletMaintenanceWorker>()
      .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
      .setInitialDelay(delaySeconds,TimeUnit.SECONDS)
      .setInputData(workDataOf("trigger" to trigger,"route" to route,
        "wake_reason" to producer?.reasonCode,"wake_deadline_unix" to producer?.deadline?.toString())).build()
    // Coalesce hints. A current owner is never replaced/cancelled by a duplicate.
    WorkManager.getInstance(context).enqueueUniqueWork("wavelength.opportunity.${route ?: "local"}",ExistingWorkPolicy.KEEP,request)
  }
}
