package engineering.lightning.wavewalletdk.client

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class ReceiptReference(val source: String, val id: String) {
  val supported get() = source in setOf("lightning_swap", "credit_receive") && id.isNotEmpty() && id.length <= 128
}
@Serializable
data class LightningReceipt(val reference: ReceiptReference,
  @SerialName("canonical_id") val canonicalId: String,
  val state: String, @SerialName("amount_sat") val amountSat: Long,
  @SerialName("created_at_unix") val createdAtUnix: Long)
@Serializable
internal data class ReceiptReadRequest(val references: List<ReceiptReference>,
  @SerialName("created_after_unix") val createdAfterUnix: Long)

/** A bounded attempt, never a proof of global catch-up or round completion. */
@Serializable
data class MaintenanceResult(val receipts: List<LightningReceipt> = emptyList(), val batches: Int = 0,
  @SerialName("needs_foreground") val needsForeground: Boolean = false,
  val interrupted: Boolean = false,
  @SerialName("budget_exhausted") val budgetExhausted: Boolean = false,
  @SerialName("maintenance_checked") val maintenanceChecked: Int = 0,
  @SerialName("maintenance_deferred") val maintenanceDeferred: Boolean = false,
  @SerialName("maintenance_more") val maintenanceMore: Boolean = false)
