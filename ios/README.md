# iOS — Wavelength wallet and WalletKit

The `ios/Sample` target is a native SwiftUI wallet named **Wavelength**. It uses
the `WalletKit` Swift package to run Wavelength inside the app process.

The backing Bitcoin wallet is Wavelength's lightweight `lwwallet` backend. It
syncs blocks and transactions through Esplora. The app does not configure or
run an LND node or use an LND wallet. Lightning payments use Wavelength's Ark
and swap services while keys and Bitcoin funds remain in the embedded,
self-custodial wallet.

The app includes:

- isolated signet, testnet3, mainnet, and development regtest wallets;
- one wallet balance including pending funds, provider-held credit, and activity on Home;
- Lightning and Bitcoin receive requests with QR codes, copy, and share;
- invoice and Bitcoin address sends with QR scanning and quote confirmation;
- cooperative exit, unilateral recovery plans and progress, on-chain sweeps,
  signed portable recovery export, and explicit refresh;
- device-managed encrypted wallets, recovery-word backup, and Face ID,
  Touch ID or device-passcode app unlock;
- Signal Dark, Porcelain Light, and the system appearance; and
- an app-switcher privacy cover and immediate auto-lock when biometrics is on.

Ordinary payment screens show Receiving, Sending, In progress, or Complete.
Protocol stages and identifiers are behind Details. Recovery retains the
funding, transaction, and block-wait information needed to act safely.
Animations emphasize amount changes, new activity, and completion; Reduce
Motion disables movement and replaces progress animation with a static icon.

The Send screen's AVFoundation scanner recognizes raw BOLT-11 invoices,
`lightning:` URIs, on-chain BIP-21 requests, and BIP-21 requests containing a
Lightning fallback. It reads QR metadata directly from the live camera and
does not capture or store photos. Scanning only fills the destination field;
the user must still review the quote and explicitly confirm the payment.

The app refreshes wallet snapshots every five seconds and also consumes the
live activity stream. The embedded Esplora wallet polls every ten seconds on
signet/testnet, every second on regtest, and every 30 seconds on mainnet. A
confirmed boarding deposit can still take up to Wavelength's 60-second
activity-reconciliation tick to move from pending to complete; pull-to-refresh
requests a new snapshot but does not bypass those daemon-owned pollers.

Lightning invoice creation asks the native mobile facade for a 20-second
request-scoped deadline. The binding marks both deadline and lifecycle
cancellation as an uncertain outcome. The app then reconciles Activity before
returning an error. If the invoice was durably created just before the response
was lost, the app recovers and displays that exact invoice; it never blindly
creates a second one after ambiguous cancellation.

New wallets use a random 32-byte encryption password stored in the device-only
Keychain with `AfterFirstUnlockThisDeviceOnly` accessibility. Creation and restore
no longer ask the user to invent a wallet password. Device authentication is on
by default for a new installation when available; an existing explicit preference
is preserved. Face ID or Touch ID uses the device passcode as its system fallback.

The UI session lock is separate from native wallet encryption. The app can read
the wallet credential unattended after the first device unlock following a reboot.
Foreground interaction, sends and recovery exports still require an unlocked UI
session. This deliberately replaces per-read biometric Keychain protection with
application-enforced authorization; it is not a Secure Enclave signing wallet.
Each network retains its own credential. The UI lock applies across networks.

Existing wallets migrate on their next successful foreground biometric or wallet
password unlock. Migration writes and reads back the exact old password before
removing the legacy protected item. There is no re-encryption or wallet reset.
A failed migration keeps the legacy source for a later retry. User-chosen legacy
passwords remain an unlock fallback; new generated passwords are never displayed.

The managed key does not move to another iPhone through iCloud or device backups.
Before replacing or erasing the original phone, transfer funds or export the
appropriate recovery package. Recovery words alone may not recover off-chain
state. Restored wallet files without their managed key show an explicit recovery
explanation and remain untouched; the app does not overwrite them with a new
seed-only wallet or claim that a seed can decrypt those files.

Background preparation and foreground takeover share lifecycle ownership. A
foreground transition waits for preparation, resumes intake, then requires UI
authentication before interaction. Healthy native work is retained. An accepted
payment or round is not cancelled merely to lock the UI or re-dial transports.

Home activity shows the payment amount, note/title, status, and local time.
Explicitly linked credit-funding entries are grouped under their invoice
payment's Details, rather than presented as a second payment. Unmatched
transfers and failed funding remain visible. The complete SDK activity and
accounting records are retained.

An invoice stays Awaiting payment until money is detected; completion alone
produces Received. Allocating a Bitcoin address creates no activity. A deposit
appears when the wallet observes a transaction. Pending invoice details reopen
the exact original QR. Optional notes and protocol details stay collapsed.

Send quotes are consumed once. A durable pending-dispatch marker reconciles
an uncertain response against Activity before another send is allowed. Refresh
also persists its selected inputs: completion requires confirmed forfeits for
all of them. Only positive evidence that every input is available again allows
Review again. A missing row or failed read never means success.

Unilateral exit is an explicit advanced action with a funding plan and a
separate acknowledgment. No cooperative failure automatically starts it.
Recovery export is read-only and does not start an exit. Recovery words alone
are not a backup of all off-chain state; preserve the wallet data and recovery
package as appropriate for the underlying protocol.

Signet, testnet, and mainnet use the operator, swap service, and Esplora
defaults compiled into the Wavelength binding when endpoint overrides are
empty. Mainnet must be selected through an explicit warning. Connection
settings display the defaults and accept custom endpoints; edits take effect
only after Save connection. Regtest requires explicit service endpoints.
Wallet files and Keychain accounts are isolated by network.

The current network can also be changed before entering the wallet—from the
first-run setup, unlock, or startup-failure screen. This prevents a persisted
network with unavailable endpoints from locking the user out of Settings.

## Build and run

The build requires macOS, Xcode, an iOS Simulator runtime, Python 3,
`xcodegen` (`brew install xcodegen`), authenticated `gh`, and the Go/gomobile
toolchain used by Wavelength's `make mobile-ios` target. Install gomobile and
gobind with `go install golang.org/x/mobile/cmd/gomobile@latest` and
`go install golang.org/x/mobile/cmd/gobind@latest`, then run `gomobile init`.
Put `$(go env GOPATH)/bin` on PATH. Xcode must use the full developer directory,
not only Command Line Tools.

[`.wavelength-ios-version`](../.wavelength-ios-version) pins Wavelength source.
The fetch script builds that exact commit with
`scripts/wavelength-ios-recovery.patch`. The narrow bridge exposes
refresh, refresh observation, full recovery inventory, cooperative-exit fee
estimation, and signed portable recovery export through gomobile. The pinned
source already includes the credit top-up correlation fix.
Android keeps its separate existing release pin.

The app enables the durable round runtime. Its typed service lookup is separate
from the persisted mailbox address, so startup and wallet reopening use the
same durable state. Replacement-round support is disabled for durable clients
until replacement lineage can be checkpointed; ordinary clients retain support.

Framework provenance includes the source commit and bridge digest. Managed
source caches are keyed by both, under
`~/.cache/wavelength-mobile-ios/<commit>-<bridge-sha256>` (or `XDG_CACHE_HOME`).
Initialization publishes only a fully prepared checkout. Source verification
compares file content rather than local Git diff formatting. Release overrides
require the complete mobile binding ABI; published releases through v0.2.1 lack
this bridge and cannot build the current Swift wrapper. Apply the bridge to a
clean pinned checkout with `git apply --index` so its new files are tracked.

The Swift wrapper retains the
bounded-read and uncertain receive-outcome contracts and exposes
independent `maxCreditSat` and `maxCreditTopupSat` send limits. Both default to
10,000 sats per payment, enabling small payments through credit. These caps
bound credit reservation and new Ark value moved into credit; they do not
request a 10,000-sat top-up. The daemon quotes the required amount, including
any rounding to the minimum Ark output. The confirmation screen shows existing
credit use, the top-up, and the new Ark outflow before dispatch. Remaining
top-up value stays in the server-held credit balance for future payments.
Wrapper callers can override either cap, including zero to disable it.

Complete Xcode's first-launch system-component installation before building.
`xcodebuild -checkFirstLaunchStatus` must succeed; if it reports pending setup,
run `sudo xcodebuild -runFirstLaunch` from your terminal and authenticate there.

Build, test, and run check a receipt containing the source commit and bridge
patch digest. A matching artifact is reusable offline. Otherwise the script
clones the pin into `~/.cache/wavelength-mobile-ios/<commit>-<bridge-sha256>`,
applies the checked-in bridge, and builds the framework. An explicit
`WAVELENGTH_DIR`
must already contain exactly that commit and bridge diff, with no unexpected
untracked source. It rebuilds each time. Source or patch mismatches fail before
replacing the staged SDK. Framework binaries stay ignored.

```bash
# Clone and build the pinned source plus mobile bridge.
./scripts/fetch-xcframework.sh --if-needed

# Or use an already prepared checkout at the exact pin with the bridge applied.
WAVELENGTH_DIR=/path/to/wavelength ./scripts/fetch-xcframework.sh

# Generate, build, install, and launch on an iPhone Simulator.
make run
```

The repository Makefile selects and boots a Simulator automatically, so a
literal placeholder UDID never needs to be copied into `xcodebuild`. These
commands work from either the repository root or `ios/Sample`:

```bash
make build
make test
make run

# Optional: pin one of the devices printed by `xcrun simctl list devices`.
make test SIMULATOR_UDID=3910E643-9CEF-46AC-83B3-E531CD2A85CA
```

`make test-signet` opts into public-service smoke coverage: create/unlock a
signet wallet, allocate a boarding address, create a Lightning invoice, and
verify that the same invoice remains in Activity after foreground recovery
and process relaunch. It also checks that pasting the invoice leaves the send
review controls visible without opening the scanner. It creates requests without
funding the wallet or sending payments. Use a dedicated Simulator with default
signet endpoints.
This does not establish funded boarding, payment settlement, or background
wake support; those require separate live tests. Normal `make test` skips
both the signet and regtest network tests.

`make test-storage-signet` runs the unit target with an isolated storage probe.
It creates an unfunded wallet alongside an app-owned SQLite database, holds an
app write transaction during wallet operations, then stops and relocates the
entire wallet directory. Reopen must preserve the identity and original invoice.
The test uses a temporary directory and no sample-app Keychain entries; it does
not launch the sample UI. Normal `make test` skips this live probe too. See the
[storage investigation](../docs/ios-storage.md) for results, the proposed host
contract and the limits of this test.

For a build already installed on a physical phone, attach the app and embedded
Go daemon directly to the terminal:

```bash
# Auto-select the first connected and unlocked iOS device.
make device-logs

# Optional when more than one phone is connected.
make device-logs DEVICE_UDID=9A5A428D-8182-5787-B7AC-C983FEAD67EC
```

The command terminates and relaunches the installed app with `devicectl`, then
streams both Swift output and the embedded daemon's stdout until `Ctrl-C`.
Nothing needs to be copied from the in-app developer screen. It does not build
or reinstall the app, so use Xcode (or the device build command used for that
build) first. The phone must be connected, unlocked, trusted by the Mac, and
have Developer Mode enabled. `make device` prints the auto-selected device ID.

`make run` and `make run-regtest` open and foreground Simulator.app after
booting the selected device. `make build` and `make test` stay headless. Set
`OPEN_SIMULATOR=0` for an intentionally headless application launch:

```bash
OPEN_SIMULATOR=0 make run
```

`xcodegen` is available from Homebrew: `brew install xcodegen`.
Use `xcrun simctl list devices available` to find the UDID. Simulator builds
must remain signed because the app stores its wallet secret in Keychain; an
unsigned build can launch but Keychain returns an entitlement error.

## Full regtest integration

The UI tests under `Sample/UITests` are opt-in because they need a live
operator, swap service, Esplora, and a way to fund and mine the wallet's
on-chain address. Point the app at any compatible local topology by exporting
its client-facing endpoints:

Explorer fixture seeding is not part of this workflow. A wallet integration
test only needs an address created by the app, one faucet payment, and mined
confirmations; it does not need Alice/Bob/Carol/Dave explorer history or
multiple synthetic rounds.

```bash
export WAVELENGTH_OPERATOR_ADDRESS=http://127.0.0.1:8080
export WAVELENGTH_SWAP_ADDRESS=http://127.0.0.1:8280
export WAVELENGTH_ESPLORA_URL=http://127.0.0.1:3000

make run-regtest
make test-regtest
```

The sample infers REST from an `http://` or `https://` address and gRPC from a
bare `host:port`; regtest gRPC is insecure when no certificate path is
supplied. `make run-regtest` forwards the exported values into the Simulator
without saving them in the app. Set `WAVELENGTH_UI_EXTERNAL_FUNDING=1` only for
the funding UI test. It prints `WAVELENGTH_FUND_THIS_ADDRESS=...` and waits
while another terminal funds the address and mines confirmations with the
local environment's own commands.

The mobile facade does not accept an operator credential, so the supplied
operator address must be a client-facing endpoint whose authentication policy
matches the public Wavelength client protocol. Keep administrative endpoints
separate and authenticated.

The live workflow covers wallet creation and unlock, address generation,
external funding, mined confirmations, Esplora reconciliation, activity
listing, activity-detail navigation, and Lightning invoice creation. Explorer
fixture seeding and repeated synthetic rounds are not required for these wallet
tests.

## WalletKit

`WalletKit` is the idiomatic Swift wrapper over the gomobile bindings: an
`actor`-based `WalletClient` with `async`/`throws` methods, an
`AsyncThrowingStream` for wallet activity, and `Codable` models. It mirrors the
Kotlin `walletkit` library.

Building requires the `Wavewalletdk.xcframework`. `scripts/fetch-xcframework.sh`
builds the exact source commit and bridge patch described above. An explicit
`WAVELENGTH_DIR` must match that commit and the complete bridge. The framework
is ignored and is not committed here.

Verified end to end on the iOS Simulator: the Swift wrapper boots the embedded
daemon, creates a wallet, connects to the signet operator mailbox, and syncs to
the chain tip (`operator=connected`, `state=ready`).

> Linker note: the embedded daemon's Go networking references `res_9_*` symbols
> from **libresolv**, so `WalletKit` declares the `resolv` linker dependency in
> `Package.swift`. Without it the link fails with "Undefined symbols
> _res_9_ninit / _nclose / _nsearch".

## Command-line simulator control

```bash
# One time: a simulator runtime (the SDK ships with Xcode; the runtime is a
# separate download) and the project generator.
xcodebuild -downloadPlatform iOS
brew install xcodegen

# Build the bindings, generate the project, build, install, and launch.
make run

# Then drive the simulator like the Android emulator:
xcrun simctl io booted screenshot ui.png

# Launch the installed wallet and use its setup or unlock screen.
xcrun simctl launch booted engineering.lightning.wavelength.wallet
```

`run-ios-sample.sh` stages the xcframework, runs `xcodegen generate` on
`ios/Sample/project.yml`, boots a simulator (creating one if needed), then
`xcodebuild` + `xcrun simctl install`/`launch`. The classic
`xcodebuild` + `xcrun simctl` stack is the foundation; on Xcode 26.3+ the
official `xcrun mcpbridge` MCP server can drive a live Xcode for agents, and
`getsentry/XcodeBuildMCP` is a headless alternative.

## Layout

```
ios/WalletKit/
  Package.swift                 SwiftPM package; binaryTarget -> Wavewalletdk.xcframework
  Sources/WalletKit/
    Bindings.swift              the only file that touches generated symbols
    WalletClient.swift          actor: async/throws API + AsyncThrowingStream
    WalletConfig.swift          Encodable config + signet() factory
    Models.swift                Codable result models
  Frameworks/                   Wavewalletdk.xcframework goes here (gitignored)
```

## Stage the framework

```bash
# Build .wavelength-ios-version plus the checked-in bridge patch. Requires
# macOS, Xcode, Go, gomobile, and authenticated gh for source checkout.
./scripts/fetch-xcframework.sh

# Or use a checkout at the exact pin with the complete bridge already applied.
# Produces sdk/wavewalletdk/mobile/build/ios/Wavewalletdk.xcframework:
WAVELENGTH_DIR=/path/to/wavelength ./scripts/fetch-xcframework.sh
```

The source build (`make mobile-ios`) runs on macOS with Xcode installed and
cross-compiles the embedded daemon for device + simulator slices.

## The generated symbol prefix

gomobile names the generated free functions after the Go package, so they are
`MobileStart`, `MobileGetInfo`, `MobileSubscribe`, and a `MobileSubscription`
class, all in a `Wavewalletdk` module. Every reference to those symbols lives in
`Bindings.swift`; if the prefix changes (the `gomobile bind -prefix` flag in
`gen_bindings.sh`), that one file is the only edit.

## WalletKit usage

```swift
import WalletKit

let client = WalletClient()
try await client.start(.signet(dataDir: dataDir))
_ = try await client.createWallet(walletPassword: Data("demo-password".utf8))

let info = try await client.getInfo()
print("height \(info.blockHeight), ready \(info.walletReady)")

for try await entry in client.activity(includeExisting: true) {
    print("\(entry.kind) \(entry.amountSat) sat \(entry.status)")
}
```

## Notification source registration

The pinned native source includes wallet-authorized subscriber feed grants and
retained shutdown ownership. `WalletClient.setNotificationFeedGrant` signs the
publisher's exact subscriber key, grant ID, classes and expiry through the
configured source. The native bridge checks source identity and subscriber
consent before using the wallet key. The returned feed token is correlation,
not mailbox-read authority. The installation signs its binding at the relay.

Register each source independently. `WalletConfig.swapNotificationIssuer` pins
the swap service's compressed public wallet identity; leaving it unset keeps
that source unsupported. Neither a push nor an offer can choose an RPC endpoint.
There is no producer relay-alias input. Legacy capability registration APIs
remain available in the wrapper for older callers, but the app uses feed setup.

These calls do not enroll a phone with APNs or run wallet recovery. The app owns
those platform responsibilities. Installation state stays in device-only
Keychain. Feed tokens must not appear in logs or notification payloads.

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

## Payment activity alerts

The app's notification settings support App Attest enrollment, private generic
payment-activity alerts and taps into Activity after wallet authentication.
Publisher configuration is empty by default. See
[the iOS notification integration](../docs/ios-notifications.md) for build keys,
credential ownership, revocation and remaining bounded-runtime work.

Release-tag overrides must expose `MobileSetHostForeground`,
`MobileRunReceiptWindow`, `MobileRunMaintenanceWindow` and
`MobileCancelReceiptWindow`, `MobileEstimateExitFee`, `MobileDiagnosticRead` and
`MobileDiagnosticLogs`, as well as the existing
recovery and subscription bridge symbols. An older release cannot build the
current Swift wrapper.

`estimateExitFee(outpoint:)` reads the selected live Bitcoin VTXO and chain tip,
then asks the operator to price its remaining lifetime. It never allocates an
address, reserves funds or submits an exit. A failed lookup remains an error;
it does not become a zero fee. Cooperative exits do not receive the pure-refresh
fee waiver. This is an advisory preview; the binding round quote still determines
the final fee. The review shows the amount, destination, destination switch and
estimated fee in that order. Confirmation waits for a usable estimate.

## Background preparation and bounded windows

Set `WalletConfig.durableRoundRuntime = true` and `hostDrivenIngress = true`
before starting the app runtime. This leaves mailbox intake paused during unlock.
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

The app may prepare the selected wallet from a cold process using its saved
credential before entering either window. It never creates a wallet, prompts for
biometrics, switches networks, or accepts an endpoint from a push. Missing keys,
legacy keys awaiting migration, and device storage before first unlock skip the
opportunity. Receipt amounts still require explicit notification consent and
matching enrolled invoice proof, independently of the UI lock.

The OS callback's twenty-second deadline includes preparation. Expiration cancels
an owned cold startup through SDK stop, or signals an admitted window by ID.
Ownership remains retained until the original native call returns. A warm runtime
is not torn down because a background opportunity failed. Foreground takeover
waits for preparation and uses `setHostForeground(true)` before ordinary calls.

The native window APIs themselves require an unlocked runtime; they do not start
one. Cold startup loses in-memory signing sessions, so durable recovery cannot
promise continuation of every round. iOS may relaunch a system-terminated app,
but a user force-quit prevents ordinary background-push relaunch. Wake delivery
and execution time are best-effort, not a guarantee of refresh before expiry.
Preserve wallet files after durable-runtime adoption.


## Diagnostics

Settings → Diagnostics uses typed read-only views of the native daemon and swap
RPCs. It remains behind the wallet's normal interaction lock. Inspection cannot
send a payment, join a round, trigger refresh or start recovery.

The VTXO inventory includes explicit pending-round states and can include spent
and forfeited history. Selecting a VTXO shows its full virtual outpoint and each
actual Bitcoin anchoring output from persisted ancestry, including nonzero
output indexes and multiple commitments. Copy and share preserve complete
identifiers. Recorded anchoring outputs do not assert current unspent status.
Large checkpoint packages are excluded from listing reads.

Refresh timing uses the daemon's block-height thresholds, independently of its
CSV delay. Missing expiry/tip metadata stays unknown. Operator free-refresh
terms are the current session snapshot; eligibility does not guarantee iOS
execution or a completed refresh. Round timing shows the operator-provided
registration opening, cutoff and planned join in local time. Historical rounds
may no longer have a registration window. These times do not schedule an iOS
wake or predict confirmation.

Logs support case-insensitive literal substring matching, highlighting,
level/source filters, pause/follow, older-record paging and explicit filtered
export with UTC timestamps. Pausing freezes the display, not native capture.
Scrolling holds the displayed snapshot while native capture and the captured
match count stay live. Buffer rotation cannot move the row being read.
Only “Follow latest” switches back to the current buffer and resumes scrolling. Log options can add a timestamped user
marker for a reproduction without changing wallet state.
The capture menu selects Info or Debug for the next wallet startup; it never
restarts an active wallet. Native history retains up to 2,000 records and two
rotating files of at most 1 MiB each. Capture is enabled by the app's
`diagnostic_logs` config flag, while other SDK hosts keep the default off.
The app excludes diagnostic directories from backup and retains
complete-until-first-user-authentication file protection. Common native
credential-bearing log records are omitted before persistence.

The background journal records actual push/scheduler callbacks, cold/retained
startup, preparation, native-window return flags and iOS expiration. It stores
at most 50 runs and 200 host events. A run interrupted by process death shows
“End not recorded”; its displayed duration stops at the last observation.
Quote/signing details remain available through native logs during the selected
run. No journal status claims global reconciliation or successful settlement.
The journal starts with this version; it cannot reconstruct earlier wakes.

The app also exposes round history, OOR/swap/credit inspection, raw public RPC
responses and a balance breakdown. Refreshing a screen samples current state;
it is not a complete historical stream of every transient protocol state.

Validation includes native anchor/shutdown and log-rotation race tests,
protobuf JSON decoding, case-insensitive literal search, complete identifier
sharing, authoritative expiry calculations and journal restart handling.
Run the opt-in, unfunded Signet UI probe with
`WAVELENGTH_UI_DIAGNOSTICS=1` in the test runner environment and select
`DiagnosticsUITests/testInspectInventoryAndFilterNativeLogs`.

Transfer summaries show local direction and a known amount. Outgoing OOR values
come from requested recipients and exclude wallet change. Incoming OOR values
come from local created-output bindings. Unknown legacy or pending values are
shown as unavailable. The VTXO inventory enriches the lightweight listing with
authoritative expiry reads, so Refresh due uses the same posture as details.

Diagnostics → Logs → Log options → Capture level selects Error, Warning, Info,
Debug or Trace for the next native wallet startup. Info is the default. Existing
Debug capture preferences carry forward until a level is selected. The capture
level controls which records the daemon produces; the display filter only
selects records already captured.

Round wake consent uses the operator offer's class mask 5: ordinary protocol
work plus scheduled and urgent round wakes. Mask 1 remains compatible. The app
rejects payment bits on operator offers and round bits on other source roles.
The wallet signs the exact accepted offer; changing relay source policy alone
cannot upgrade an existing wallet grant. Renew notification setup after a
capable producer and publisher are activated.

Round pushes use the existing silent maintenance callback. The host-driven SDK
uses a short registration jitter and keeps the normal signing validation and
nonce recovery fence. Neither an APNs acceptance nor a returned maintenance
window proves a round completed. Physical-device background registration and
signing remain a separate end-to-end acceptance test.
