package engineering.lightning.wavelength.data

import engineering.lightning.wavewalletdk.client.RefreshObservation
import engineering.lightning.wavewalletdk.client.WalletVTXO
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

internal data class RefreshExpiryGroup(val label: String, val amountSat: Long)

/** Estimate expiry using Bitcoin's ten-minute target interval. */
internal fun refreshExpiryGroups(funds: List<WalletVTXO>, height: Long): List<RefreshExpiryGroup> {
  return funds.groupBy { fund ->
    val blocks = fund.batchExpiry - height
    val hours = (blocks + 3) / 6
    when {
      fund.status == "expired" -> -1L
      fund.batchExpiry <= 0 || height <= 0 -> Long.MAX_VALUE
      blocks <= 0 -> -1L
      blocks < 6 -> 0L
      hours < 24 -> hours
      else -> ((blocks + 72) / 144) * 24
    }
  }.toSortedMap().map { (hours, group) ->
    val label = when (hours) {
      -1L -> "Expired"
      0L -> "In less than an hour"
      1L -> "In about 1 hour"
      24L -> "In about 1 day"
      Long.MAX_VALUE -> "Expiry unavailable"
      else -> if (hours < 24) "In about $hours hours" else "In about ${hours / 24} days"
    }
    RefreshExpiryGroup(label, group.sumOf { it.amountSat })
  }
}
