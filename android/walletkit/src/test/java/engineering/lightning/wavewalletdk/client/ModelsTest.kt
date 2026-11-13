package engineering.lightning.wavewalletdk.client

import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class ModelsTest {
  private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

  @Test fun activityCarriesRequestAndCorrelationAcrossSnapshots() {
    val entry = json.decodeFromString<Entry>("""{
      "ID":"payment-1", "Kind":"receive", "Status":"pending", "AmountSat":3200,
      "CreatedAt":"2026-11-13T10:00:00Z", "Note":"Android test", "Cursor":42,
      "Progress":{"Phase":"waiting_for_payment", "PaymentHash":"abc"},
      "Request":{"Type":"lightning", "LightningInvoice":"lntbs...", "PaymentHash":"abc"},
      "FutureField":true
    }""")
    assertEquals(42L, entry.cursor)
    assertEquals("abc", entry.progress?.paymentHash)
    assertEquals("lntbs...", entry.request?.lightningInvoice)
    assertEquals("Android test", entry.note)
  }

  @Test fun quoteKeepsCreditSeparateFromBalanceDebit() {
    val quote = json.decodeFromString<PrepareSendResult>("""{
      "SendIntentID":"intent-1", "AmountSat":999, "ExpectedTotalOutflowSat":1500,
      "TotalOutflowKnown":true, "SelectedOutpoints":["tx:0"],
      "CreditPreview":{"CreditAppliedSat":1000,"CreditTopupSat":1500}
    }""")
    assertEquals(999L, quote.amountSat)
    assertEquals(1500L, quote.expectedTotalOutflowSat)
    assertEquals(1000L, quote.creditPreview?.creditAppliedSat)
    assertEquals(listOf("tx:0"), quote.selectedOutpoints)
  }

  @Test fun emptyGoSlicesAndOptionalFieldsAcceptNull() {
    val result = json.decodeFromString<ListResult>("""{"Activity":{"Entries":null}}""")
    assertEquals(emptyList<Entry>(), result.activity?.entries)
  }
}
