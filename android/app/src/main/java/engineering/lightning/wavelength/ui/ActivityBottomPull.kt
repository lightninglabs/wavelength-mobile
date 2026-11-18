package engineering.lightning.wavelength.ui

import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp

/** Use the drag left over at the end of the list and commit on release. */
@Composable
internal fun Modifier.activityBottomPull(
  list: LazyListState,
  enabled: Boolean,
  load: () -> Unit,
): Modifier {
  val allowed = rememberUpdatedState(enabled)
  val onLoad = rememberUpdatedState(load)
  val threshold = with(LocalDensity.current) { 72.dp.toPx() }
  val connection = remember(list, threshold) {
    object : NestedScrollConnection {
      private var pull = 0f

      override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
        if (source == NestedScrollSource.UserInput) {
          pull = if (allowed.value && !list.canScrollForward && available.y < 0) {
            pull - available.y
          } else {
            0f
          }
        }
        return Offset.Zero
      }

      fun release() {
        val shouldLoad = allowed.value && !list.canScrollForward && pull >= threshold
        cancel()
        if (shouldLoad) onLoad.value()
      }

      fun cancel() { pull = 0f }
    }
  }
  LaunchedEffect(list, connection) {
    list.interactionSource.interactions.collect { event ->
      when (event) {
        is DragInteraction.Stop -> connection.release()
        is DragInteraction.Cancel -> connection.cancel()
        else -> Unit
      }
    }
  }
  return nestedScroll(connection)
}
