package engineering.lightning.wavelength

import engineering.lightning.wavelength.ui.paymentHandleTopPadding
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Test

class PaymentSheetLayoutTest {
  @Test fun handleKeepsTheOriginalExpandedPositionAcrossViewportHeights() {
    val statusBar = 63
    // On the taller viewport the sheet already clears the status bar. On
    // the shorter one its expanded edge is 47 px down, leaving 16 px to pad.
    for ((bodySpace, expectedGap, expectedPadding) in listOf(
      Triple(1388, 69, 0), Triple(960, 47, 16),
    )) {
      val padding = paymentHandleTopPadding(bodySpace, statusBar)
      val available = bodySpace - padding
      assertEquals(expectedPadding, padding)
      assertEquals(expectedGap, available - (available * .95f).roundToInt())
    }
  }
}
