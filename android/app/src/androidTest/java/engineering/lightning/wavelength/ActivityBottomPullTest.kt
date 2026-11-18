package engineering.lightning.wavelength

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import engineering.lightning.wavelength.ui.activityBottomPull
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ActivityBottomPullTest {
  @get:Rule val compose = createComposeRule()

  @Test fun reachingTheEndWaitsForAnUpwardPullAndRelease() {
    val count = mutableIntStateOf(30)
    var loads = 0
    compose.setContent {
      val list = rememberLazyListState()
      LazyColumn(
        Modifier.height(360.dp).fillMaxWidth().testTag("list")
          .activityBottomPull(list, enabled = count.intValue == 30) {
            loads++
            count.intValue += 30
          },
        state = list,
      ) {
        items(count.intValue, key = { it }) {
          Box(Modifier.height(60.dp).fillMaxWidth().testTag("row-$it"))
        }
      }
    }

    val list = compose.onNodeWithTag("list")
    list.performScrollToIndex(29)
    compose.runOnIdle { assertEquals(0, loads) }
    list.performTouchInput {
      down(Offset(center.x, center.y))
      moveBy(Offset(0f, -20f))
      up()
    }
    compose.runOnIdle { assertEquals(0, loads) }
    list.performTouchInput {
      down(Offset(center.x, bottom - 20))
      moveBy(Offset(0f, top - center.y))
      cancel()
    }
    compose.runOnIdle { assertEquals(0, loads) }
    list.performTouchInput {
      swipe(Offset(center.x, bottom - 20), Offset(center.x, top + 20), durationMillis = 650)
    }
    compose.runOnIdle { assertEquals(1, loads) }
    compose.onNodeWithTag("row-29").assertIsDisplayed()
    list.performScrollToIndex(59)
    list.performTouchInput { swipeUp(durationMillis = 650) }
    compose.runOnIdle { assertEquals(1, loads) }
  }
}
