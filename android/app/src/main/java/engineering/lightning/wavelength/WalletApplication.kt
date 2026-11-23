package engineering.lightning.wavelength

import android.app.Application
import engineering.lightning.wavelength.background.WalletWork
import engineering.lightning.wavelength.background.WalletFirebase
import engineering.lightning.wavelength.data.WalletSession

class WalletApplication : Application() {
  override fun onCreate() {
    super.onCreate()
    WalletFirebase.prepare(this)
    WalletWork.schedule(this)
  }
  val wallet by lazy { WalletSession(this) }
}
