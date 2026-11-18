package engineering.lightning.wavelength

import engineering.lightning.wavewalletdk.client.ActivityList
import engineering.lightning.wavewalletdk.client.Entry
import engineering.lightning.wavewalletdk.client.EntryProgress
import engineering.lightning.wavelength.data.ActivityHistory
import java.time.Instant
import org.junit.Assert.*
import org.junit.Test

class ActivityHistoryTest {
  @Test fun historyCanGrowPastTheLegacySnapshotLimit() {
    val history = ActivityHistory()
    val rows = List(1001) { index ->
      Entry(id = "entry-$index", createdAt = Instant.ofEpochSecond(1001L - index).toString())
    }
    rows.chunked(ActivityHistory.PAGE_SIZE.toInt()).forEachIndexed { index, batch ->
      val more = (index + 1) * ActivityHistory.PAGE_SIZE < rows.size
      history.append(ActivityList(batch, hasMore = more, nextCursor = "page-${index + 1}"), history.state.nextCursor)
      assertEquals(rows.take((index + 1) * ActivityHistory.PAGE_SIZE.toInt()), history.state.entries)
    }
    assertEquals(rows, history.state.entries)
    assertNull(history.state.nextCursor)
  }

  @Test fun olderPagesAndChangesUseIndependentBoundaries() {
    val history = ActivityHistory()
    val first = row("a", 15).copy(status = "pending")
    val last = row("b", 15)
    history.append(ActivityList(listOf(first, last), hasMore = true, nextCursor = "page-2"), null)

    val new = row("new", 16)
    val between = row("aa", 15)
    val unseen = row("c", 15)
    val complete = first.copy(status = "complete", updatedAt = "2026-11-18T00:00:17Z")
    history.mergeChanges(listOf(new, between, unseen, complete, complete))
    assertEquals(listOf(new, complete, between, last), history.state.entries)
    assertEquals("page-2", history.state.nextCursor)

    history.append(ActivityList(listOf(unseen, row("old", 14))), "page-2")
    assertEquals(listOf("new", "a", "aa", "b", "c", "old"), history.state.entries.map { it.id })
    assertNull(history.state.nextCursor)
    history.mergeChanges(listOf(row("backdated", 13)))
    assertEquals("backdated", history.state.entries.last().id)
  }

  @Test fun emptyOrHiddenPagesStillAdvanceAndInvalidTokensPreserveRetry() {
    val history = ActivityHistory()
    history.append(ActivityList(hasMore = true, nextCursor = "page-2"), null)
    try {
      history.append(ActivityList(hasMore = true, nextCursor = "page-2"), "page-2")
      fail("The same cursor must not be accepted twice")
    } catch (_: IllegalStateException) {
      assertEquals("page-2", history.state.nextCursor)
    }
    history.append(ActivityList(listOf(row("older", 13))), "page-2")
    assertEquals(listOf("older"), history.state.entries.map { it.id })
    assertNull(history.state.nextCursor)
  }

  @Test fun boardingOverlayCanBecomeCanonicalWithTheSameId() {
    val history = ActivityHistory()
    val unconfirmed = row("deposit-address", 16).copy(kind = "deposit", status = "pending",
      progress = EntryProgress(phase = "waiting_for_confirmation"))
    val payment = row("payment", 15)
    history.append(ActivityList(listOf(unconfirmed, payment)), null)
    history.updateOverlay(listOf(unconfirmed.copy(createdAt = "2026-11-18T00:00:17Z")))
    assertEquals(listOf(unconfirmed, payment), history.state.entries)

    val confirmed = unconfirmed.copy(progress = EntryProgress(txid = "tx", confirmationHeight = 20))
    history.mergeChanges(listOf(confirmed))
    history.updateOverlay(listOf(unconfirmed))
    assertEquals(listOf(confirmed, payment), history.state.entries)
  }

  private fun row(id: String, second: Int) = Entry(id = id, kind = "send", status = "complete",
    createdAt = "2026-11-18T00:00:${second}Z")
}
