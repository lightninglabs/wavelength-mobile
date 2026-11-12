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

## Stable SDK refresh — 2026-11-06

The iOS wrapper now uses the published Wavelength v0.2.1 framework, pinned in
`.wavelength-ios-version`. The Android pin remains separate. Build, test, and
run check the staged framework's release receipt, replacing an older or
unidentified artifact before compiling. The native storage probe reported
SDK version `0.2.1`.

Swift invoice sends default to a 10,000-sat credit reservation cap and an
independent 10,000-sat Ark-to-credit top-up cap. The quote determines actual
spending. The review screen shows existing credit use, the required top-up,
and new Ark outflow; the dashboard shows available and reserved server-held
credit separately from the wallet's available Ark balance.

Validation used Xcode 26.6 (17F113) and a new iPhone 17 Pro Simulator on iOS
26.5. It did not open the earlier funded Simulator wallet.

| Check | Observed result |
|---|---|
| Unit tests | 15 passed, including independent credit caps and explicit opt-outs |
| Live micro payment quote | A 10-sat invoice selected credit and quoted a 1,000-sat top-up; zero caps rejected the same sub-floor invoice |
| Native storage | Identity and the exact invoice survived closing, directory relocation, reopen, and unlock; idle stop took 0.297 seconds and reopen/readiness took 2.754 seconds |
| Signet UI | Request creation, copy/paste, foreground recovery, and process relaunch passed in 94.7 seconds |
| Framework staging | Changing the pin or explicit override replaced the SDK; a matching receipt worked offline; a failed download preserved the installed SDK |

The micro payment probe uses two disposable, unfunded wallets and never calls
`Send`. It proves quote routing and authorization forwarding, not funded
micro payment settlement. The funded checks below exercise settlement
separately. Physical-device behavior, OS background wake, and upgrading the
earlier funded wallet remain unverified in this refresh.

### Funded receive, credit payments, and restart — 2026-11-06

The iPhone 17 Pro Simulator's closed signet wallet directory was backed up,
then the app created a fresh wallet. Its configured signet operator, swap,
and Esplora overrides were saved through Settings. The CLI peer used Wavelength
`12854f30`, built with the wallet RPC and swap runtime enabled; the app retained
the published v0.2.1 SDK.

| Check | Observed result |
|---|---|
| Routed Lightning receive | A separate signet LND paid the app's 20,000-sat invoice once; payer succeeded with a 2-sat routing fee, and the original app receive completed with 20,000 spendable Ark sats |
| First micro payment | The app quoted and paid a distinct 10-sat peer invoice through credit, with a 1,000-sat top-up and zero payment fee |
| Credit reuse | A second distinct 10-sat invoice quoted 10 sats of existing credit, zero top-up, and zero new Ark outflow; both payer and receiver completed |
| Final balances | App: 19,000 Ark sats and 980 available credit sats; peer: 20 available credit sats and no reserved credit |
| Process restart | Rebuild and relaunch retained the same four complete activity IDs and amounts: one receive, two micro payments, and one top-up; saved endpoint overrides also persisted |

The original receive and both outgoing payment hashes each identify exactly
one complete app operation. The peer retained both original receive IDs.
The app's 19,000 Ark sats, its 980 credit sats, and the peer's 20 credit sats
sum to the received 20,000 sats. The 2-sat routing fee was paid separately by
the Lightning payer.

This run exposed a presentation error: an activity row without a Lightning
request or payment hash was assumed to be on-chain. The SDK's persisted
credit-funding row did not identify a rail, so the app called it "On-chain
sent". Unknown send rails now use the neutral "Bitcoin sent" title and
"Not reported" in details. Explicit Lightning, on-chain, and Ark requests
retain their corresponding rail labels; no amount or settlement state changes.

## Wallet redesign and main SDK — 2026-11-06

This dated entry records the November 6 build and validation, which superseded
the stable SDK pin above. That build used Wavelength source
`43c517cf6fefe9aae3f9c2a879d0b11f6ff407a2` plus the mobile bridge in
`scripts/wavelength-ios-recovery.patch`. The current source pin is recorded in
[`.wavelength-ios-version`](../.wavelength-ios-version); the results below
belong to the November 6 build, not each later pin.

The bridge added refresh, positive refresh observation, nonterminal Bitcoin
recovery inventory, and the complete signed portable recovery export. Source
staging verified the exact commit and whole patch diff; Android was unchanged.

The app now has one balance and activity on Home, separate provider-held
credit, Signal Dark and Porcelain Light, the wave wordmark and app icon, and
optional Keychain-enforced Face ID/Touch ID unlock. Ordinary payment screens
keep protocol stages behind Details. The network selector uses the same
plain rows, spacing, and checkmark selection as the rest of the interface.

Recovery screens expose cooperative exit, an explicit unilateral exit with
funding/CSV progress, on-chain sweep preview, and signed recovery export.
Export and unilateral selection include expired and reserved funds rather
than only the spendable inventory. Export does not broadcast or start an exit.
Refresh persists the exact selected inputs; only confirmed forfeits complete
it. Positive evidence that all inputs returned to LIVE allows a new review.

The funded staging wallet retained its 19,000 spendable sats and 980 credit
sats across the SDK/UI upgrade. A further 10-sat credit-only payment completed
with zero payment fee, no new top-up, and no change to the spendable balance.
Available credit became 970 sats. Cold launch and biometric unlock retained
these amounts and the same activity.

A manual refresh test exposed unconditional foreground teardown interrupting
an assembling round. Foreground recovery now keeps a healthy daemon alive;
only an unhealthy connection triggers restart after state-creating calls finish.
The interrupted refresh correctly offers Action needed after the daemon
positively reports its original inputs as available again. A newly reviewed
refresh was accepted with a 269-sat advisory estimate. A brief background and
biometric-unlock transition retained the process and pending operation; final
round confirmation was not yet observed. A queued refresh is
not labeled Complete merely because its inputs leave the spendable balance.

Device compilation and signing pass. Physical-device installation, camera
behavior, and OS background wake remain unverified. Cooperative/unilateral exit
and on-chain sweep settlement require separate funded acceptance; their UI and
native APIs are implemented, but compilation alone does not prove settlement.

Final validation on Xcode 26.6 / iOS 26.5:

| Check | Result |
|---|---|
| Swift and live signet tests | 20 passed, 0 failed; the separate opt-in storage probe skipped |
| Credit quote | 10-sat invoice quoted a top-up within the independent caps; zero-cap authorization was rejected |
| Receive/copy/lifecycle UI | Bitcoin address, Lightning invoice, exact copy/paste, foreground, and cold relaunch passed again after hiding raw requests behind Details (51.6 seconds) |
| Native bridge | SDK and mobile package tests passed; changed-source formatting and local lint passed |
| Framework provenance | Release cache, source pin/patch checks, offline reuse, and failed replacement preservation passed |
| Device build | Generic iPhone Debug build signed successfully; no connected phone was available for installation |


### Physical-device credit activity repair — 2026-11-06

The iPhone received a 10,000-sat signet invoice, then paid one 999-sat peer
invoice. The receiver recorded exactly one completed 999-sat receive. Device
activity also contained a separate 1,000-sat funding transfer, initially shown
as another Payment because it had no credit-top-up label or payment link.

The durable credit operation identified that transfer's exact session and
1,000-sat top-up. Its ledger spent a 10,000-sat input and returned 9,000 sats in
change. Existing history code already netted self-change for display, but the
credit correlation still compared the gross input amount with the net top-up.
[Wavelength PR #1530](https://github.com/lightninglabs/wavelength/pull/1530)
fixes that comparison without changing accounting or dispatch. The regression
fails before the fix; the full swapwallet suite, formatting, and local lint
pass. At the time of this repair, the source bridge patch carried the fix.
The current pinned native source includes it, so the bridge no longer does.

After rebuilding and installing over the existing iPhone app, a read-only
inspection confirmed the same original payment and funding records, now linked
by the invoice payment hash and the credit-top-up label. No wallet reset or
second payment was used. The app groups that verified funding leg under the
999-sat payment's Details. Unknown, unmatched, and failed funding entries remain
visible. Activity adds status and local time beside the note/title; payment
screens keep note, status, and time above Details.

Validation: 20 Swift tests passed, two opt-in network/storage probes skipped;
the live signet request/copy/foreground/relaunch UI test passed separately.
The rebuilt source framework and device-signed iPhone app compiled, installed,
and launched successfully.

## Cooperative batch exits — 2026-11-12

Settings → Exit supports several selected VTXOs through one native batch
request. The review sums exact per-input advisory estimates and uses one common
destination. Each input still creates its own on-chain output. A device-local,
network-scoped receipt is atomically saved before dispatch. Accepted inputs share
the returned canonical activity identifier; unknown inputs remain separate and
cannot be automatically retried. Corrupt history blocks new admission. No
receipt is replayed after restart. These receipts contain public outpoints,
amounts and destination, not wallet credentials.

Simulator unit and unfunded Signet navigation checks cover admission receipts
and the separate unilateral route. A funded physical-device batch exit is left
for beta testing. The current native source is recorded in
[`.wavelength-ios-version`](../.wavelength-ios-version).
