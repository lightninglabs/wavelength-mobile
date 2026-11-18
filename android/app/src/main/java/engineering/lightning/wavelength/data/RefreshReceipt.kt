package engineering.lightning.wavelength.data

import engineering.lightning.wavewalletdk.client.RefreshObservation
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.nullable

@Serializable internal data class RefreshReceipt(val outpoints: List<String>, val amountSat: Long)

/** An explicit retry may only preview outputs the wallet classifies as available. */
internal fun RefreshObservation.retrySelection(receipt: RefreshReceipt): List<String>? {
  if (complete) return emptyList()
  return remaining.takeIf { retryAllowed && it.isNotEmpty() && it.all(receipt.outpoints::contains) }
}

internal fun refreshJournal(directory: File) = FundJournal(File(directory, "refresh.json"), RefreshReceipt.serializer().nullable, null)

internal val RefreshObservation?.label: String get() = when {
  this == null -> "Checking status"
  complete -> "Complete"
  retryAllowed && confirmed > 0 -> "Partially refreshed"
  retryAllowed -> "Not completed"
  else -> "In progress"
}
