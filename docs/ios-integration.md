# Native iOS integration log

The first integration uses PR #6 and the published Wavelength v0.1.2 framework.
The project tracker is [wavelength-sdk#77](https://github.com/lightninglabs/wavelength-sdk/issues/77).

## Environment

- Xcode 26.2 (17C52), XcodeGen 2.46.0.
- iPhone 16 Pro Simulator, iOS 18.5.
- Standard signet and the release's default operator, swap, and Esplora endpoints.
- Wavelength-managed storage in the app sandbox and the existing wallet password
  in Keychain. Tests must retain both when checking process recovery.

## Baseline — 2026-09-14

At commit `799785f`, `make test` passed 14 unit tests and skipped four opt-in
network tests. `make test-signet` passed those unit tests and its live UI test
(67.5 seconds), with three regtest tests skipped. `make run` built, installed,
and launched the app.

The signet test creates a boarding address and a 50,000-sat Lightning invoice.
It finds the same invoice after a background/foreground transition and after
process termination/relaunch, with automatic wallet creation disabled on the
second launch. No funds move in this test.

## Funded receive probe — 2026-09-15

The original unpaid invoice reached the SDK's `failed` status with failure code
`expired`; its swap session was `Expired`. The app previously showed a red
"Lightning receive failed" row with a green positive amount. The presentation
now uses "Lightning invoice expired", an "Expired" badge, and a neutral requested
amount. This uses the SDK's explicit expiry code and preserves its stored status.
`make test` passed all 14 unit tests with four live tests skipped. `make run`
rebuilt and launched the app, and the expired entry was checked in Simulator.

A fresh 1,500-sat invoice was submitted once to the public
[ArkFaucet Lightning endpoint](https://arkfaucet.com/guides/lightning-signet/).
The endpoint returned HTTP 200 with `success: true` and `status: sent`.
The receiver still showed zero available balance, `waiting_for_payment` activity,
and an `InvoiceCreated` swap with no funded vHTLC. Foreground recovery and a full
process relaunch retained the request but did not establish settlement.

This is an unresolved cross-system result, not a successful receive or a proven
Wavelength defect. A controlled signet payer or local regtest peer must provide
the payer's terminal result and correlate it with the wallet's activity. Do not
create replacement requests or repeat payments merely because one side times out.

## Next acceptance sequence

The funded checks below were subsequently exercised on 2026-09-15; external
Lightning routing and physical-device wake remain open.

1. Fund a boarding address above the operator's current minimum and observe
   pending funds, chain confirmation, and completion into spendable balance.
2. Pay a fresh invoice from a controlled Lightning peer; verify the payer's
   terminal result, the original activity ID, receive completion, and balance.
3. Send a small test payment to that peer and compare the reviewed quote, fees,
   terminal status, and resulting balance on both sides.
4. Repeat a receive with the app absent, then relaunch. Verify catch-up without a
   replacement request or duplicate credit. Interrupt a send and reconcile its
   existing operation before attempting another.
5. Run the lifecycle matrix on a physical device, including lock, suspension,
   connectivity loss, delayed wake, and process termination.

The unfunded smoke test does not establish OS-driven background execution,
funded crash recovery, or seed-only restore.

## Funded boarding and receiver recovery — 2026-09-15

Two deposits to the same boarding address, 1,000,000 and 224,348 sats, confirmed
at signet height 322191. The app showed their combined 1,224,348 sats as pending
while the Ark round was in progress. The round confirmed at height 322192 and
the app then showed 1,223,838 spendable sats and a completed deposit.

An isolated second iPhone 16 Pro Simulator ran the same v0.1.2 native framework.
Its wallet retained its funds after relaunch with automatic creation disabled.

| Check | Observed result |
|---|---|
| First payment | Primary paid the peer's 25,000-sat BOLT11 invoice; both sessions reached `Completed` with the same payment hash |
| Quote and balance | `In Ark` quote: 25,000 sats, zero fee; primary moved from 1,223,838 to 1,198,838 sats; peer received 25,000 sats |
| Receiver absent | Primary created a 10,000-sat invoice, then its process was terminated before the peer sent; peer persisted `WaitingForClaim`, primary remained `InvoiceCreated` |
| Receiver catch-up | Primary was relaunched without automatic creation; the existing receive and peer's existing send reached `Completed`, with no replacement invoice or duplicate credit |
| Final balances | Primary 1,208,838 sats; peer 15,000 sats; both payments had zero quoted and recorded fees |

These payments exercised the `In Ark` settlement route selected for invoices
between Wavelength wallets. They do not establish routed Lightning payments to
an external node. The stopped-receiver test proves funded process catch-up; it
does not prove an OS background wake or arbitrary crash recovery at every phase.

The manual send test also exposed two sample-app problems: the Form row invoked
both Paste and Scan, and a long invoice expanded the editor enough to hide review
controls. The buttons now use an independent borderless style and the editor has
a fixed, scrollable height. On iOS 16 and later, the system `PasteButton` also
avoids blocking a direct clipboard read on a paste-permission dialog. That dialog
blocked the first automated regression run, which was interrupted before rerunning
with the system control. The signet smoke test covers pasting the original
invoice and reaching review without the scanner opening.
The test scrolls the long invoice until Copy is visible in the lazy Form and
waits for the asynchronous paste to deliver the exact invoice.
The final `make test-signet` run passed all 14 unit tests and the expanded live
test (53.8 seconds), with three regtest tests skipped and the Simulator's original
automatic pasteboard synchronization setting restored. Read-only checks after
relaunch also confirmed one completed activity/session per payment and the exact
final balances above.

### Remaining fee-reporting finding

The combined boarding deposit reports a 417-sat fee, while the difference between
funded and spendable amounts is 510 sats. In v0.1.2,
[`sumDepositsByAddress`](https://github.com/lightninglabs/wavelength/blob/v0.1.2/swapwallet/history.go)
sums deposit amounts but retains the representative input's fee. The two input
fee allocations are 417 and 93 sats, which explains the missing 93 sats in the
aggregated activity fee. The native app displays the SDK's value.

Track the correction in the engine separately from this pinned integration
baseline. Related fee-reporting work is tracked in
[wavelength#866](https://github.com/lightninglabs/wavelength/issues/866) and
[wavelength#994](https://github.com/lightninglabs/wavelength/issues/994); this
specific aggregation case is recorded in the project EPIC. Its regression should
combine two funded inputs at one address and
assert both the summed amount and summed fee, including reprojecting already
persisted activity. The wallet's spendable balance was consistent throughout
the two payments; this finding concerns activity fee reporting.

## Storage observations

The running native wallet creates three stores under its network data directory:

| Store | State | Integration question |
|---|---|---|
| `waved.db` (SQLite) | Ark, activity, and durable actor state | Preserve transaction boundaries between checkpoints and outgoing work |
| `swaps.db` (SQLite) | Receive/pay sessions and recovery metadata | Coordinate migrations, interruption, and reconciliation with the daemon store |
| `wallet.db` (native btcwallet/bbolt) | Keys and on-chain wallet state | Define backup, lock-time access, and recovery independently of the SQL stores |

Swift currently configures the storage location through `dataDir`; it cannot
inject an existing application database. Sharing a directory is therefore not
equivalent to sharing the host's SQL connection or persistence implementation.
The next storage experiment should define connection, schema, migration, and
transaction ownership before choosing a cross-language adapter. Projecting wallet
activity into an app's business database is a separate, narrower integration.

The [storage and lifecycle investigation](ios-storage.md) records the proposed
host contract, source audit, and executable probe for independent app storage
and relocation of a closed wallet directory.
