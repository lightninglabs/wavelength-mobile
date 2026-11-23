package engineering.lightning.wavelength.ui

import android.Manifest
import android.content.pm.PackageManager
import engineering.lightning.wavelength.data.SendDestination
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeView
import com.journeyapps.barcodescanner.CameraPreview
import com.journeyapps.barcodescanner.DefaultDecoderFactory
import engineering.lightning.wavelength.data.WalletNetwork

@Composable internal fun ScanInvoiceButton(network: WalletNetwork, enabled: Boolean, onInvoice: (String) -> Unit) {
  val context = LocalContext.current
  var scanning by remember { mutableStateOf(false) }
  var error by remember { mutableStateOf<String?>(null) }
  val permission = Manifest.permission.CAMERA
  val requestCamera = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
    if (granted) scanning = true
    else error = "Allow camera access in Settings to scan. You can also paste or type the invoice."
  }

  TextButton(enabled = enabled, onClick = {
    if (ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) scanning = true
    else requestCamera.launch(permission)
  }) { Text("Scan") }

  if (scanning) {
    AlertDialog(
      onDismissRequest = { scanning = false },
      title = { Text("Scan a payment request") },
      text = {
        InvoiceCamera(onCode = { payload ->
          scanning = false
          val invoice = scannedInvoice(payload, network)
          if (invoice != null) onInvoice(invoice)
          else error = "Use a ${network.title} payment QR code."
        }, onError = {
          scanning = false
          error = "Camera unavailable. Paste or type the invoice."
        })
      },
      confirmButton = { TextButton({ scanning = false }) { Text("Cancel") } },
    )
  }
  error?.let { message ->
    AlertDialog(onDismissRequest = { error = null }, title = { Text("Scan unavailable") },
      text = { Text(message) }, confirmButton = { TextButton({ error = null }) { Text("OK") } })
  }
}

internal fun scannedInvoice(payload: String, network: WalletNetwork): String? {
  val target = runCatching { SendDestination.parse(payload) }.getOrNull() ?: return null
  if (target.lightning) return target.value.takeIf(network::acceptsInvoice)
  val address = target.value.lowercase()
  val prefix = when (network) {
    WalletNetwork.MAINNET -> listOf("bc1", "1", "3")
    WalletNetwork.REGTEST -> listOf("bcrt1", "m", "n", "2")
    else -> listOf("tb1", "m", "n", "2")
  }
  // Keep the complete URI so a BIP21 amount survives scanning.
  return payload.trim().takeIf { prefix.any(address::startsWith) && address.length in 14..90 }

}

@Composable private fun InvoiceCamera(onCode: (String) -> Unit, onError: () -> Unit) {
  val context = LocalContext.current
  val accept by rememberUpdatedState(onCode)
  val fail by rememberUpdatedState(onError)
  val preview = remember(context) {
    BarcodeView(context).apply {
      decoderFactory = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE))
      addStateListener(object : CameraPreview.StateListener {
        override fun cameraError(error: Exception) = fail()
        override fun previewSized() {}
        override fun previewStarted() {}
        override fun previewStopped() {}
        override fun cameraClosed() {}
      })
    }
  }
  AndroidView(factory = { preview }, modifier = Modifier.fillMaxWidth().aspectRatio(1f))
  LifecycleResumeEffect(preview) {
    preview.decodeSingle { accept(it.text) }
    preview.resume()
    onPauseOrDispose {
      preview.stopDecoding()
      preview.pause()
    }
  }
}
