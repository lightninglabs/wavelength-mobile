package engineering.lightning.wavelength

import android.app.Application
import engineering.lightning.wavelength.data.WalletSession

class WalletApplication : Application() {
  val wallet by lazy { WalletSession(this) }
}
