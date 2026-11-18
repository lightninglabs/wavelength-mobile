package engineering.lightning.wavelength.ui

import android.content.Intent
import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowOutward
import androidx.compose.material.icons.outlined.SouthWest
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import engineering.lightning.wavelength.data.*
import engineering.lightning.wavewalletdk.client.InvoiceDetails
import engineering.lightning.wavewalletdk.client.Entry
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun PaymentActions(session: WalletSession, state: WalletUiState) {
  var screen by remember { mutableStateOf<String?>(null) }
  val payment by session.payments.state.collectAsStateWithLifecycle()
  val ready = state.info?.serverConnected == true
  Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
    Column(Modifier.weight(1f)) {
      Button({ session.payments.clearPresentation(); screen = "Send" }, Modifier.fillMaxWidth().height(54.dp),
        enabled = ready, shape = androidx.compose.foundation.shape.RoundedCornerShape(15.dp)) {
        Icon(Icons.Outlined.ArrowOutward, null, Modifier.size(19.dp)); Spacer(Modifier.width(7.dp)); Text("Send")
      }
    }
    Column(Modifier.weight(1f)) {
      Button({ session.payments.clearPresentation(); screen = "Receive" }, Modifier.fillMaxWidth().height(54.dp),
        enabled = ready, shape = androidx.compose.foundation.shape.RoundedCornerShape(15.dp),
        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.surface, contentColor = MaterialTheme.colorScheme.onSurface)) {
        Icon(Icons.Outlined.SouthWest, null, Modifier.size(19.dp)); Spacer(Modifier.width(7.dp)); Text("Receive")
      }
    }
  }
  if (!ready) Text("Connecting", Modifier.padding(top = 12.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
  if (payment.pending != null || payment.blocked) TextButton({ screen = if (payment.pending?.kind == "receive") "Receive" else "Send" }) {
    Text(if (payment.pending?.kind == "receive") "Checking request" else "Checking payment")
  }
  if (screen != null) {
    val dismiss = { if (!payment.busy) screen = null }
    ModalBottomSheet(onDismissRequest = dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
      containerColor = MaterialTheme.colorScheme.background, sheetGesturesEnabled = !payment.busy,
      properties = ModalBottomSheetProperties(shouldDismissOnBackPress = !payment.busy)) {
      BackHandler(payment.busy) {}
      Column(Modifier.fillMaxWidth().fillMaxHeight(.95f).imePadding()) {
        Box(Modifier.fillMaxWidth().height(64.dp)) {
          Text(screen!!, Modifier.align(Alignment.Center), style = MaterialTheme.typography.titleMedium)
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
          when {
            payment.pending != null || payment.blocked -> {
              payment.pending?.let {
                if (it.balanceSweep && it.recipientSat == null) Text("Balance debit")
                Amount(it.recipientSat ?: it.amountSat)
              }
              StatusLine(if (payment.pending?.kind == "receive") "Checking request" else "Checking payment", true)
              Text("Check Activity before trying again.", color = MaterialTheme.colorScheme.onSurfaceVariant)
              payment.error?.let { PaymentError(it) }
              WalletButton("Check status", !payment.busy) { session.scope.launchRefresh(session) }
            }
            screen == "Send" -> SendScreen(session, payment, state)
            else -> ReceiveScreen(session, payment, state)
          }
        }
      }
    }
  }
}

private fun kotlinx.coroutines.CoroutineScope.launchRefresh(session: WalletSession) {
  launch { session.refresh() }
}

@Composable private fun SendScreen(session: WalletSession, payment: PaymentUiState, wallet: WalletUiState) {
  val invoice = rememberTextFieldState()
  val note = rememberTextFieldState()
  when {
    payment.result != null -> {
      val entry = wallet.activity.firstOrNull { it.id == payment.result.id } ?: payment.result
      Amount(kotlin.math.abs(entry.amountSat))
      StatusLine(entry.statusLabel, entry.showsProgress)
    }
    payment.quote != null -> {
      val quote = payment.quote
      if (payment.balanceSweep && !quote.feeKnown) Text("Balance debit")
      Amount(if (payment.balanceSweep && quote.feeKnown) quote.amountSat - quote.expectedFeeSat else quote.amountSat)
      CopyRow("Destination", quote.destinationSummary)
      ReceiptRow("Network", if (quote.rail == "onchain") "On-chain" else "Lightning")
      if (quote.invoiceDescription.isNotEmpty()) Text(quote.invoiceDescription, color = MaterialTheme.colorScheme.onSurfaceVariant)
      HorizontalDivider()
      ReceiptRow("Fee", if (quote.feeKnown) sats(quote.expectedFeeSat) else "Unavailable")
      quote.creditPreview?.let { credit ->
        if (credit.creditAppliedSat > 0) ReceiptRow("Credit used", sats(credit.creditAppliedSat))
        if (credit.creditTopupSat > 0) ReceiptRow("Credit top-up", sats(credit.creditTopupSat))
      }
      if (quote.totalOutflowKnown || quote.feeKnown) ReceiptRow(if (quote.creditPreview == null) "Total" else "Balance debit", sats(quote.expectedTotalOutflowSat))
      HorizontalDivider()
      if (quote.warning.isNotEmpty()) Text(quote.warning, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
      WalletButton(if (payment.busy) "Sending…" else "Confirm", !payment.busy) { session.payments.send() }
      TextButton({ session.payments.clearPresentation() }, enabled = !payment.busy) { Text("Edit") }
    }
    payment.busy -> StatusLine("Preparing payment", true)
    else -> SendDraft(invoice, note, wallet.network, false, session.client::decodeInvoice) { amount, max, fee ->
      session.payments.prepare(invoice.text.toString(), note.text.toString(), amount, max, fee)
    }
  }
  payment.error?.let { PaymentError(it) }
}

@Composable private fun SendOptions(decode: suspend (String, String) -> InvoiceDetails, network: WalletNetwork, raw: String,
  note: TextFieldState, busy: Boolean, onReview: (Long, Boolean, Long) -> Unit) {
  val parsed = remember(raw) { runCatching { SendDestination.parse(raw) } }
  val dest = parsed.getOrNull()
  var details by remember { mutableStateOf<InvoiceDetails?>(null) }
  var decodeError by remember { mutableStateOf<String?>(null) }
  LaunchedEffect(dest, network) {
    if (dest?.lightning == true) {
      try { details = decode(dest.value, network.wire) }
      catch (error: kotlinx.coroutines.CancellationException) { throw error }
      catch (error: Exception) { decodeError = error.message }
    }
  }
  if (raw.isNotBlank()) (parsed.exceptionOrNull()?.message ?: decodeError)?.let { Text(it, color = MaterialTheme.colorScheme.error) }
  val amount = rememberTextFieldState()
  val fee = rememberTextFieldState()
  var maximum by remember { mutableStateOf(false) }
  val fixed = details?.amountSat ?: dest?.requestedSat
  val ready = dest != null && (!dest.lightning || details != null)
  if (ready) {
    details?.description?.takeIf { it.isNotBlank() }?.let { Text(it) }
    if (fixed != null) Amount(fixed)
    else {
      if (!maximum) WalletField("Amount (sats)", amount, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
      Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Use available balance", Modifier.weight(1f))
        Switch(maximum, { maximum = it }, enabled = !busy)
      }
    }
  }
  DetailSection("Options") {
    WalletField("Note", note)
    WalletField("Maximum fee (sats)", fee, placeholder = "Automatic", keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
  }
  val maxFee = if (fee.text.isEmpty() || fee.text.toString() == "0") 0L else wholeSats(fee.text.toString())
  val entered = wholeSats(amount.text.toString())
  WalletButton(if (busy) "Preparing…" else "Review", ready && !busy && maxFee != null && (fixed != null || maximum || entered != null)) {
    onReview(if (fixed != null || maximum) 0 else entered!!, maximum, maxFee!!)
  }
}

@Composable internal fun SendDraft(
  invoice: TextFieldState, note: TextFieldState, network: WalletNetwork, busy: Boolean, decode: suspend (String, String) -> InvoiceDetails, onReview: (Long, Boolean, Long) -> Unit,
) {
  val clipboard = LocalClipboardManager.current
  WalletField("Invoice or Bitcoin address", invoice, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
  Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
    ScanInvoiceButton(network, enabled = !busy) { value -> invoice.edit { replace(0, length, value) } }
    TextButton({ invoice.edit { replace(0, length, clipboard.getText()?.text.orEmpty()) } }) { Text("Paste") }
  }
  key(invoice.text.toString().trim(), network) {
    SendOptions(decode, network, invoice.text.toString(), note, busy, onReview)
  }
}

@Composable private fun ReceiveScreen(session: WalletSession, payment: PaymentUiState, wallet: WalletUiState) {
  val amount = rememberTextFieldState()
  val note = rememberTextFieldState()
  var onchain by remember { mutableStateOf(false) }
  val currentEntry = wallet.activity.firstOrNull { it.id == payment.result?.id } ?: payment.result
  if (payment.request.isNotEmpty()) {
    currentEntry?.let { StatusLine(it.statusLabel, it.showsProgress) }
    RequestCard(payment.request)
    DetailSection { CopyRow(if (onchain) "On-chain" else "Invoice", payment.request) }
  } else {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
      listOf("Lightning", "On-chain").forEachIndexed { index, label ->
        SegmentedButton(selected = onchain == (index == 1), onClick = { onchain = index == 1 },
          enabled = !payment.busy, shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(label) }
      }
    }
    if (!onchain) {
      WalletField("Amount (sats)", amount, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
      DetailSection("Options") { WalletField("Note", note) }
    }
    WalletButton(if (payment.busy) "Creating…" else if (onchain) "Show address" else "Create request",
      !payment.busy && (onchain || (amount.text.toString().toLongOrNull() ?: 0) > 0)) {
      if (onchain) session.payments.deposit() else session.payments.receive(amount.text.toString().toLong(), note.text.toString())
    }
  }
  payment.error?.let { PaymentError(it) }
}

@Composable private fun PaymentError(raw: String) {
  val message = paymentFailure(raw)
  Text(message, color = MaterialTheme.colorScheme.error)
  if (message != raw) DetailSection("Technical details") { CopyRow("Error", raw) }
}

@Composable fun RequestCard(value: String) {
  val bitmap = remember(value) {
    val matrix = QRCodeWriter().encode(value, BarcodeFormat.QR_CODE, 1000, 1000,
      mapOf(EncodeHintType.MARGIN to 4, EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M))
    Bitmap.createBitmap(matrix.width, matrix.height, Bitmap.Config.ARGB_8888).apply {
      val pixels = IntArray(matrix.width * matrix.height) { i -> if (matrix[i % matrix.width, i / matrix.width]) android.graphics.Color.BLACK else android.graphics.Color.WHITE }
      setPixels(pixels, 0, matrix.width, 0, 0, matrix.width, matrix.height)
    }.asImageBitmap()
  }
  Image(bitmap, "Payment request QR code", Modifier.fillMaxWidth().widthIn(max = 420.dp).aspectRatio(1f).background(Color.White).padding(4.dp), filterQuality = androidx.compose.ui.graphics.FilterQuality.None)
  val clipboard = LocalClipboardManager.current
  val context = LocalContext.current
  Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
    Column(Modifier.weight(1f)) { WalletButton("Copy", secondary = true) { clipboard.setText(AnnotatedString(value)) } }
    Column(Modifier.weight(1f)) { WalletButton("Share", secondary = true) {
      context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, value) }, null))
    } }
  }
}

@Composable internal fun PendingRequest(entry: Entry) {
  if (!entry.awaitingPayment) return
  val request = entry.request?.lightningInvoice?.ifEmpty { null } ?: entry.request?.onchainAddress.orEmpty()
  if (request.isNotEmpty()) RequestCard(request)
}

@Composable private fun ReceiptRow(label: String, value: String) {
  Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
    Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant); Text(value)
  }
}

@Composable private fun StatusLine(text: String, pending: Boolean) {
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
    if (pending) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
    Text(text)
  }
}
