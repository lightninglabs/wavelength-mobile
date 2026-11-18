package engineering.lightning.wavelength

import engineering.lightning.wavelength.background.PushTarget
import engineering.lightning.wavelength.background.RegistrationState
import engineering.lightning.wavelength.background.RemoteGrant
import org.junit.Assert.*
import org.junit.Test

class RelayRegistrationTest {
  @Test fun delayedBindingCannotRestoreDisabledOrReplacedRoute() {
    val old = PushTarget("first", "signet", "wallet", "connection")
    val next = old.copy(route = "second")
    val pending = RegistrationState(desired = old, grant = RemoteGrant(old, "grant", 100))
    assertNull(pending.bound)
    val live = pending.publish(old, 80)
    assertEquals(80L, live.bound!!.expiresAt)
    val disabled = live.select(null)
    assertNull(disabled.publish(old, 100).bound)
    assertEquals(pending.grant, disabled.grant)
    val replaced = disabled.select(next)
    assertNull(replaced.publish(old, 100).bound)
    assertNull(replaced.publish(next, 100).bound)
    val newGrant = replaced.copy(grant = RemoteGrant(next, "new-grant", 200))
    assertEquals("second", newGrant.publish(next, 180).bound!!.id)
  }
}
