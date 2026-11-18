package engineering.lightning.wavelength.background

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import engineering.lightning.wavelength.MainActivity
import engineering.lightning.wavelength.R
import engineering.lightning.wavelength.WalletApplication

/**
 * Opt-in foreground service that keeps the process, and so the embedded wallet,
 * connected while the app is in the background. It owns no wallet state: the
 * session decides what runs while the service is attached, and the UI stays
 * locked behind its normal authentication gate.
 */
class WalletKeepAliveService : Service() {
  private val wallet get() = (application as WalletApplication).wallet
  private var attached = false

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent?.action == ACTION_STOP) { stop(); return START_NOT_STICKY }
    // Android requires the notification promptly after every start request,
    // and can refuse it when the process was restarted in the background.
    val started = runCatching {
      ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(),
        if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0)
    }.isSuccess
    if (!started || !wallet.state.value.keepRunning) { stop(); return START_NOT_STICKY }
    if (!attached) { attached = true; wallet.attachKeepAlive(::stop) }
    return START_STICKY
  }

  override fun onDestroy() {
    if (attached) { attached = false; wallet.detachKeepAlive() }
    super.onDestroy()
  }

  private fun stop() {
    ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    stopSelf()
  }

  private fun notification() = NotificationCompat.Builder(this, CHANNEL).apply {
    if (Build.VERSION.SDK_INT >= 26) getSystemService(NotificationManager::class.java).createNotificationChannel(
      NotificationChannel(CHANNEL, "Background connection", NotificationManager.IMPORTANCE_LOW).apply {
        description = "Shown while Wavelength keeps your wallet connected in the background"
        setShowBadge(false)
      })
    val immutable = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    val open = Intent(this@WalletKeepAliveService, MainActivity::class.java)
      .setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    val stop = Intent(this@WalletKeepAliveService, WalletKeepAliveService::class.java).setAction(ACTION_STOP)
    setSmallIcon(R.drawable.ic_notification_wave)
    setContentTitle("Wavelength is running")
    // No balance, amount or network: this text is visible on the lock screen.
    setContentText("Keeping your wallet connected")
    setContentIntent(PendingIntent.getActivity(this@WalletKeepAliveService, 0, open, immutable))
    addAction(0, "Stop", PendingIntent.getService(this@WalletKeepAliveService, 0, stop, immutable))
    setOngoing(true)
    setOnlyAlertOnce(true)
    setShowWhen(false)
    setCategory(NotificationCompat.CATEGORY_SERVICE)
    setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
    setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
  }.build()

  companion object {
    const val CHANNEL = "wavelength.background-connection.v1"
    private const val NOTIFICATION_ID = 0x57_41_56 // "WAV"
    private const val ACTION_STOP = "engineering.lightning.wavelength.STOP_KEEP_ALIVE"

    /**
     * Android only admits a foreground service start while the app is visible,
     * so call this from the activity or a settings action. A refused start
     * leaves the wallet on scheduled background maintenance.
     */
    fun start(context: Context) {
      runCatching { ContextCompat.startForegroundService(context, Intent(context, WalletKeepAliveService::class.java)) }
    }

    fun stop(context: Context) {
      context.stopService(Intent(context, WalletKeepAliveService::class.java))
    }
  }
}
