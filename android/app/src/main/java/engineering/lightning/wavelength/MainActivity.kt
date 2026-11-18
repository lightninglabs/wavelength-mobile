package engineering.lightning.wavelength

import android.app.KeyguardManager
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import engineering.lightning.wavelength.ui.WalletApp
import engineering.lightning.wavelength.ui.WalletTheme

class MainActivity : FragmentActivity() {
  private val wallet get() = (application as WalletApplication).wallet

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    if (!BuildConfig.DEBUG) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    enableEdgeToEdge()
    setContent { WalletTheme { WalletApp(wallet, ::authenticate) } }
  }

  override fun onStart() { super.onStart(); wallet.resume() }
  override fun onStop() { wallet.pause(); super.onStop() }

  private fun authenticate(success: () -> Unit) {
    val authenticators = BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL
    if (!getSystemService(KeyguardManager::class.java).isDeviceSecure) {
      // Emulator and devices without a screen lock still use encrypted storage.
      success(); return
    }
    if (BiometricManager.from(this).canAuthenticate(authenticators) != BiometricManager.BIOMETRIC_SUCCESS) {
      wallet.reportError(IllegalStateException("Device authentication unavailable")); return
    }
    val prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
      override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) { success() }
    })
    prompt.authenticate(BiometricPrompt.PromptInfo.Builder().setTitle("Unlock Wavelength")
      .setAllowedAuthenticators(authenticators).build())
  }
}
