# iOS — Wavelength wallet and WalletKit

The `ios/Sample` target is a native SwiftUI wallet named **Wavelength**. It uses
the `WalletKit` Swift package to run Wavelength inside the app process.

The backing Bitcoin wallet is Wavelength's lightweight `lwwallet` backend. It
syncs blocks and transactions through Esplora. The app does not configure or
run an LND node or use an LND wallet. Lightning payments use Wavelength's Ark
and swap services while keys and Bitcoin funds remain in the embedded,
self-custodial wallet.

The app includes:

- separate signet, testnet3, and mainnet wallets;
- an Esplora-synced confirmed balance and pending amounts;
- Lightning and on-chain receive requests with QR codes, copy, and share;
- Lightning and on-chain sends with camera QR scanning and a quote-and-confirm
  step;
- live, searchable activity and a detailed inspection screen;
- recovery-word creation and restore;
- a per-network wallet password stored in the device-bound Keychain; and
- a privacy cover that hides wallet data in app-switcher snapshots.

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

After iOS has actually backgrounded the process, returning to the foreground
restarts and unlocks the same embedded wallet so its external gRPC transports
are re-dialled on the current network path. Teardown waits for any in-flight
state-creating call to return first; it is never used as a cancellation
shortcut for a payment or receive request with an uncertain outcome.

Activity follows the same lifecycle vocabulary as `wavecli activity`: issuing
an invoice is shown as a pending request, while “received” is reserved for a
completed receive. Merely allocating an on-chain address is not activity; its
deposit row appears only after Esplora observes a payment, using the observed
amount rather than the optional amount hint. Transaction IDs and on-chain
request addresses in the detail view link to the selected network's
mempool.space explorer, or to a custom configured Esplora deployment. Pending
Lightning receive details can reopen, copy, and share the original invoice as
a QR code without creating a replacement request.

Signet and testnet use the service and Esplora defaults compiled into the
Wavelength binding. Mainnet must be selected through an explicit warning. Its
backing wallet can sync from Wavelength's default mainnet Esplora URL, but a
Wavelength boarding address still needs trusted operator terms; Lightning also
needs a trusted swap endpoint. Those operations stay disabled until the user
enters the required endpoints in Settings. Wallet files and Keychain accounts
are isolated by network.

The current network can also be changed before entering the wallet—from the
first-run setup, unlock, or startup-failure screen. This prevents a persisted
network with unavailable endpoints from locking the user out of Settings.

## Build and run

The build requires `Wavewalletdk.xcframework`. The fetch script downloads a
released binding by default or builds one from a local Wavelength checkout.

```bash
# Released binding. Requires an authenticated gh CLI with repository access.
./scripts/fetch-xcframework.sh

# Or build from a local Wavelength checkout.
WAVELENGTH_DIR=/path/to/wavelength ./scripts/fetch-xcframework.sh

# Generate, build, install, and launch the app on an automatically selected
# iPhone Simulator.
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
downloads it from the `wavelength` GitHub release by default (or builds it from
a `WAVELENGTH_DIR` checkout); it is not committed here.

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

# Or run headless (no taps): autostart boots + creates a wallet on launch.
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
# Downloads the latest wavelength release by default (needs the gh CLI
# authenticated to an account with read access to wavelength). Set
# WAVELENGTH_VERSION=<tag> to pin a release.
./scripts/fetch-xcframework.sh

# Or build from a local checkout against an unreleased daemon (macOS + Xcode).
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
