package engineering.lightning.wavelength.data

import engineering.lightning.wavewalletdk.client.ActivityList
import engineering.lightning.wavewalletdk.client.Entry
import java.time.Instant
import java.util.UUID

data class ActivityHistoryState(
  val sessionId: UUID = UUID.randomUUID(),
  val entries: List<Entry> = emptyList(),
  val loaded: Boolean = false,
  val nextCursor: String? = null,
  val loading: Boolean = false,
  val failed: Boolean = false,
)

/** The wallet session serializes reads and publishes one immutable view of this history. */
internal class ActivityHistory {
  private data class Row(val entry: Entry) {
    val created: Instant = runCatching { Instant.parse(entry.createdAt) }.getOrDefault(Instant.MIN)
  }

  private val order = compareByDescending<Row> { it.created }.thenBy { it.entry.id }
  private val canonical = mutableMapOf<String, Row>()
  private var oldest: Row? = null
  private var overlay: Entry? = null
  var state = ActivityHistoryState()
    private set

  fun loading() { state = state.copy(loading = true, failed = false) }
  fun finish(failed: Boolean) { state = state.copy(loading = false, failed = failed) }

  fun append(page: ActivityList, requested: String?) {
    val next = page.nextCursor.takeIf { page.hasMore }
    check(!page.hasMore || (!next.isNullOrEmpty() && next != requested)) {
      "Activity returned an invalid continuation"
    }
    if (requested == null) replaceOverlay(page.entries)
    page.entries.filterNot(::isBoardingOverlay).forEach { entry ->
      val row = Row(entry)
      canonical[entry.id] = row
      if (oldest?.let { order.compare(it, row) < 0 } != false) oldest = row
    }
    state = state.copy(loaded = true, nextCursor = next, entries = entries())
  }

  /** Rows below the loaded range will be returned by a later history page. */
  fun mergeChanges(updates: List<Entry>) {
    var changed = false
    updates.forEach { entry ->
      val row = Row(entry)
      if (entry.id in canonical || (state.loaded && state.nextCursor == null) ||
        oldest?.let { order.compare(row, it) <= 0 } == true || overlay?.id == entry.id
      ) {
        canonical[entry.id] = row
        if (entry.id == overlay?.id) overlay = null
        changed = true
      }
    }
    if (changed) state = state.copy(entries = entries())
  }

  fun updateOverlay(head: List<Entry>) {
    val previous = overlay
    replaceOverlay(head)
    if (previous != overlay) state = state.copy(entries = entries())
  }

  private fun replaceOverlay(head: List<Entry>) {
    val observed = head.firstOrNull(::isBoardingOverlay)?.takeUnless { it.id in canonical }
    // The SDK stamps this transient row with the time of each observation.
    if (observed?.id != overlay?.id || observed?.amountSat != overlay?.amountSat) overlay = observed
  }

  private fun entries(): List<Entry> = buildList {
    overlay?.takeUnless { it.id in canonical }?.let { add(it) }
    addAll(canonical.values.sortedWith(order).map { it.entry })
  }

  // Same predicate as the native projector. Confirmed boarding can share the ID.
  private fun isBoardingOverlay(entry: Entry): Boolean {
    val progress = entry.progress ?: return false
    return entry.kind == "deposit" && entry.status == "pending" &&
      progress.phase == "waiting_for_confirmation" &&
      progress.txid.isEmpty() && progress.confirmationHeight == 0L
  }

  companion object {
    const val PAGE_SIZE = 30L
  }
}
