package engineering.lightning.wavewalletdk.client

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Finite read-only views implemented by the native SDK. */
enum class DiagnosticView(val wire: String) {
  VTXOS("vtxos"), VTXO("vtxo"), ANCHORS("anchors"), ROUNDS("rounds"), ROUND("round"),
  INFO("info"), BALANCE("balance"), OOR("oor"), SWAPS("swaps"), CREDITS("credits")
}

@Serializable
internal data class DiagnosticRequest(
  @SerialName("View") val view: String,
  @SerialName("Outpoint") val outpoint: String = "",
  @SerialName("RoundID") val roundId: String = "",
  @SerialName("History") val history: Boolean = false,
  @SerialName("PageToken") val pageToken: String = "",
)

@Serializable
data class DiagnosticLog(
  @SerialName("ID") val id: String,
  @SerialName("Time") val time: Long,
  @SerialName("Level") val level: String,
  @SerialName("Source") val source: String,
  @SerialName("Message") val message: String,
) {
  fun matches(query: String) = query.isEmpty() || "$level $source $message".contains(query, ignoreCase = true)
}

@Serializable
data class DiagnosticLogSnapshot(
  @SerialName("Entries") val entries: List<DiagnosticLog>? = null,
  @SerialName("HistoryUnavailable") val historyUnavailable: Boolean = false,
)
