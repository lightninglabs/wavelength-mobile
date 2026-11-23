package engineering.lightning.wavelength

import engineering.lightning.wavewalletdk.client.WalletClient
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class NativeInvoiceTest {
  @Test fun validatesSignedTermsBeforeRequestingAnAmount() = runBlocking {
    val client = WalletClient()
    val open = client.decodeInvoice(OPEN, "regtest")
    assertNull(open.amountSat)
    assertEquals("Coffee with Alex", open.description)
    assertEquals(25_000L, client.decodeInvoice(FIXED, "regtest").amountSat)
    assertTrue(runCatching { client.decodeInvoice(OPEN, "signet") }.isFailure)
    assertTrue(runCatching { client.decodeInvoice(EXPIRED, "regtest") }.isFailure)
  }

  companion object {
    private const val OPEN = "lnbcrt1pj48ugqpp59gqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqdq6gdhkven9v5s8w6t5dqsyzmr90qxq8zals8sqp3rd80lel9jpeccahy93q8p0mzx6lqj4zq2z0qxuf0sfpn5pdn5hh8queetm9kmd2e205m8cvtxvc0hj7l6yep5ckfyg9xs753p77wcp25m2jx"
    private const val FIXED = "lnbcrt250u1pj48ugqpp59gqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqdq6gdhkven9v5s8w6t5dqsyzmr90qxq8zals8sqtvg4lu5xz7cy89e2mnxuazfjglremld0nhd87udtf03pxme95pt4fstpduaz2u4g5dknwnghyw3al2vll3s5swgrvd4ewg6ghvervkcqkprr23"
    private const val EXPIRED = "lnbcrt1pj48ugqpp59gqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqdq6gdhkven9v5s8w6t5dqsyzmr90qxqrrss5y4h4y723pt8rru8c2epcy6j5q64mupt3kap48u2w0yn4h8zcw3jefxar5wesswsfqwd32zn9ajyhsgna8dvcee3ttq9v4u43wxe8agq09rs0g"
  }
}
