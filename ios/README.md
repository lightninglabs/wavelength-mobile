# iOS WalletKit SDK

`WalletKit` is the Swift wrapper around the embedded Wavelength wallet. It
provides typed network configuration, asynchronous wallet calls, and resumable
activity through `AsyncThrowingStream`. The existing `WavewalletdkSample`
diagnostic demo remains unchanged in this SDK change. The native wallet UI is
a separate change.

The embedded Bitcoin wallet uses `lwwallet` and Esplora. Lightning payments use
Wavelength's operator and swap services. Select signet, testnet3, mainnet, or
regtest through `WalletConfig`; mainnet requires explicit opt-in. Empty service
endpoints defer to the SDK's compiled defaults.

## Build and test

Use macOS with Xcode, an iOS Simulator runtime, Python 3, `xcodegen`, authenticated
`gh`, Go, and gomobile. Complete Xcode's first-launch setup. Install the Go
mobile tools and place `$(go env GOPATH)/bin` on PATH:

```bash
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
gomobile init

./scripts/fetch-xcframework.sh --if-needed
make build
make test
make run
```

`.wavelength-ios-version` pins Wavelength source at
`80ef7d08c121e6f68deeb76ecd7d554d10cd6788`. The fetch script applies
`scripts/wavelength-ios-recovery.patch`, builds the iOS/device and Simulator
slices, and stages the ignored framework under `ios/WalletKit/Frameworks`.
The patch exposes refresh, confirmed-input observation, recovery
inventory, complete signed recovery export, and native send-admission errors.
Credit funding correlation after self-change is already in the source pin.

The staged receipt includes the exact source commit and bridge digest. A
matching artifact is reusable offline; a different pin or bridge requires a
rebuild. The default source cache is
`~/.cache/wavelength-mobile-ios/<commit>-<bridge-sha256>` (or under
`XDG_CACHE_HOME` when set). Cache initialization is atomic, so an interrupted
clone or patch application can be retried without manual cleanup.
An explicit `WAVELENGTH_DIR` must contain that exact commit and whole bridge
diff, with no unexpected untracked source. Verification compares file content
and does not depend on local Git diff formatting.
Apply the bridge to a clean pinned checkout with
`git -C /path/to/wavelength apply --index /path/to/wavelength-mobile/scripts/wavelength-ios-recovery.patch`;
`--index` tracks the new bridge files for provenance verification.

Release-tag overrides retain the packaged-release download path, but the
release must expose all binding functions used by this wrapper, including
`MobileRecoveryInventory`, `MobileObserveRefresh`, `MobileRefresh`, and
`MobileExportExits`, `MobileSetNotificationSubscription`,
`MobileSetHostForeground`, `MobileRunReceiptWindow`,
`MobileRunMaintenanceWindow`, and `MobileCancelReceiptWindow`.
Published releases through v0.2.1 lack this bridge and
cannot build the current Swift wrapper. Use the repository's source pin until
a compatible release is published. Android keeps its independent release pin in
`.wavelength-version`.

`make test` runs the SDK tests. The live quote and storage tests skip unless
explicitly enabled:

```bash
make test-signet
make test-storage-signet
bash scripts/tests/fetch-xcframework.sh
```

The signet quote probe creates disposable, unfunded wallets and never sends a
payment. The storage probe checks host SQLite coexistence and relocation of a
closed wallet directory. Use `SIMULATOR_UDID` to select a specific simulator.
`make device-logs` attaches to an already installed diagnostic sample; its
bundle identifier can be overridden with `BUNDLE_ID`.

## Integration contracts

Wallet reads use bounded native contexts. A receive deadline or lifecycle
cancellation can occur after durable invoice creation: reconcile existing
activity before creating another request. Send quotes are single-use. Callers
must retain payment identity and reconcile uncertain dispatch outcomes.

Credit use and credit top-up have independent per-payment limits. Both default
to 10,000 sats in the Swift wrapper; explicit zero disables that authorization.
These are ceilings, not requested top-up amounts. Display the actual quote and
keep provider-held credit distinct from wallet funds.

Cooperative exit and explicit unilateral recovery use separate paths. Recovery
export signs a portable package without broadcasting or starting an exit.
Refresh observation completes only after all selected inputs have confirmed
forfeits; absence from live inventory is not success. Retry permission requires
positive evidence that all original inputs are available again.

Activity helpers group only explicitly linked credit funding under an invoice
payment. They preserve raw SDK records, unrelated transfers, unmatched funding,
and failed funding. Original request data, fees, hashes, and lifecycle states
remain available for inspection.

Keep wallet keys and the managed data directory under the host application's
ownership. A seed alone does not back up all off-chain state. See the
[storage investigation](../docs/ios-storage.md) and
[integration checks](../docs/ios-integration.md).

## Notification source registration

The pinned native source includes signed operator and swap notification
registration and retained shutdown ownership. `WalletClient` accepts a typed
`NotificationSubscription.register` or `.remove`. Register each configured
source independently. The operator receives only a wake capability. Supply an
optional alert capability only to a source that can classify incoming work.
`WalletConfig.swapNotificationIssuer` pins the swap service's compressed public
wallet identity; leave it unset to keep that source unsupported. Registration
uses the existing gRPC connection. Push payloads cannot supply endpoints or pins.

These calls do not enroll a phone with APNs, attest an installation, or run wallet
recovery. The app owns those platform responsibilities. Capabilities belong in
Keychain and must not appear in logs or notification payloads.

A `WalletError.isStopPending` result means the native singleton still owns
cleanup. Retain the client and repeat `stop()` before starting another daemon.
`isRunning == false` alone does not prove cleanup has finished.

The recovery bridge patch now contains only the remaining additive native APIs;
the pinned SDK already includes the credit top-up correlation fix and its test.
The framework is built locally from the exact source and recorded patch digest.
No unpublished release asset or invented checksum is used.

`activity` and `incomingPayments` accept the last durable `Entry.cursor` to
replay missed transitions. Persist it only after processing that entry. `list`
accepts the opaque `ActivityList.nextCursor` for complete keyset pagination.
Notification recovery must not truncate its catch-up to the UI’s latest page.

## Warm receipt and maintenance windows

Set `WalletConfig.durableRoundRuntime = true` before adopting these host APIs.
Keep it enabled independently of notification consent. `setHostForeground(false)`
joins continuous ingress while retaining the daemon and domain workers. The host
must serialize against state-creating wallet calls. `runReceiptWindow` checks one
locally enrolled invoice; only complete source/canonical proof may supply an
amount, after the host validates consent, identity and event correlation.

`runMaintenanceWindow` needs no invoice. It attempts current-tip expiry for a
bounded page of existing VTXO owners and pumps native round work. It returns no
receipts and never authorizes a payment banner. Use it for ordinary protocol wakes
and scheduled background opportunities. Both windows accept 1 through 20 seconds
and share `cancelReceiptWindow` with a unique invocation ID. Cancellation signals
expiry; the original call retains native ownership until its actual return.

Resume with `setHostForeground(true)` before ordinary foreground calls. Do not
stop, reopen or unlock a wallet from an expiry handler. These APIs require an
already-unlocked retained runtime; they do not promise global catchup, safe
suspension or a hard wall-clock bound for uncooperative dependencies. Preserve the
wallet files and use a compatible forward fix after durable-runtime adoption.
