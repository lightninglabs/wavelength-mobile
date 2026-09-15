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

Simulator foregrounding and process persistence do not establish OS-driven
background execution, funded crash recovery, or seed-only restore.

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
