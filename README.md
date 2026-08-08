# wavelength-mobile

`wavelength-mobile` runs the
[wavelength](https://github.com/lightninglabs/wavelength) wallet — a
self-custodial Bitcoin wallet system written in Go that unifies an Ark client, a
Lightning swap engine, and an on-chain wallet behind one daemon (`waved`) —
directly inside a mobile app. The whole daemon is embedded in the app's own
process through [`gomobile`](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile),
so a user can board into Ark, hold and transfer VTXOs, swap into and out of the
Lightning Network, send and receive on-chain, and unilaterally exit to the chain
at any time — all from their phone, while keeping sole custody of their coins.

There is no separate daemon process and no open network port: the app calls the
embedded wallet across a private in-memory gRPC channel, so nothing ever listens
on a socket. This repo holds the idiomatic Kotlin and Swift wrappers over the
gomobile bindings, plus sample apps that drive them end to end.

## How the pieces fit

```mermaid
flowchart TD
    SDK["wavelength / sdk/wavewalletdk/mobile<br/>gomobile-safe Go facade over the embedded daemon"]
    AAR["Wavewalletdk.aar<br/>(Android native lib + Kotlin classes)"]
    XCF["Wavewalletdk.xcframework<br/>(iOS native lib + Swift classes)"]
    KT["android/walletkit<br/>Kotlin wrapper: suspend + Flow"]
    SW["ios/WalletKit<br/>Swift wrapper: async + AsyncThrowingStream"]
    APP_A["android/app<br/>sample app"]
    APP_I["ios/Sample<br/>sample app"]

    SDK -->|gomobile bind| AAR
    SDK -->|gomobile bind| XCF
    AAR --> KT
    XCF --> SW
    KT --> APP_A
    SW --> APP_I
```

The Go facade and the binding build live in **wavelength**
(`sdk/wavewalletdk/mobile`, `make mobile-android` / `mobile-ios`). This repo
consumes the bindings and shows an app driving them end to end: boot the
embedded wallet, create a key, sync the chain from Esplora, and read balances.

## Repository layout

| Path | Contents |
|------|----------|
| `android/walletkit/` | Idiomatic Kotlin wrapper (`suspend` + `Flow` + typed models) over the generated bindings. The Android library other apps depend on. |
| `android/app/` | Sample Android app (Jetpack Compose, AGP 9) that drives `walletkit`. |
| `ios/WalletKit/` | Idiomatic Swift wrapper (`actor` + `async` + `AsyncThrowingStream` + `Codable`). Mirrors the Kotlin library. |
| `scripts/fetch-aar.sh` | Downloads `Wavewalletdk.aar` from the `wavelength` GitHub release (or builds it from a `WAVELENGTH_DIR` checkout) and stages it under `android/walletkit/libs`. |
| `scripts/fetch-xcframework.sh` | Same for the iOS `Wavewalletdk.xcframework`. |
| `docs/` | Architecture, the Android workflow, and signet setup. |

Both the Android and iOS wrappers and their sample apps run end to end — Android
on an emulator, iOS on the Simulator — booting the embedded wallet, creating a
wallet, and syncing signet to the chain tip. wavelength CI builds the bindings
on release tags, and the fetch scripts pull them from the release.

## Quick start (Android)

You need three things:

1. The [`gh` CLI](https://cli.github.com/) authenticated to an account with
   read access to `wavelength` (`gh auth login`). `fetch-aar.sh` downloads the
   `.aar` from the `wavelength` GitHub release by default; no Go or gomobile
   toolchain is needed. (To build the binding from source against an unreleased
   daemon instead, set `WAVELENGTH_DIR` to a local checkout — that path needs
   the Android + gomobile toolchain and a modern JDK.)
2. The Android SDK and NDK. The [`android` CLI](https://developer.android.com/tools/agents/android-cli)
   installs them: `android sdk install platform-tools emulator
   platforms/android-36 build-tools/36.1.0 ndk/29.0.14206865
   system-images/android-36/google_apis/arm64-v8a`.
3. A modern JDK (17 or newer).

```bash
# 1. Fetch the binding and stage it here. Downloads the latest wavelength
#    release by default; set WAVELENGTH_VERSION=<tag> to pin a release, or
#    WAVELENGTH_DIR=<checkout> to build from source instead.
./scripts/fetch-aar.sh

# 2. Build the sample app.
cd android && ./gradlew :app:assembleDebug

# 3. Run it on an emulator (or a device).
android emulator start medium_phone
android run --apks=app/build/outputs/apk/debug/app-debug.apk
```

The `.aar` carries the daemon compiled for every Android ABI, so it is large
(150 MB and up). `fetch-aar.sh` stages it and `.gitignore` keeps it out of
the repo.

## The API

Use the **wrapper**, not the raw bindings. The Kotlin `WalletClient`
(`engineering.lightning.wavewalletdk.client`) gives every call a `suspend` function
that runs off the main thread and returns a typed model, and exposes wallet
activity as a `Flow`:

```kotlin
val client = WalletClient()
client.start(WalletConfig.signet(dataDir = dir))     // suspend; blocks off-thread
client.createWallet("my-password".toByteArray())
val info = client.getInfo()                           // typed Info
client.activity(includeExisting = true).collect { e -> /* Entry */ }
```

Swift's `WalletClient` mirrors this with `async`/`throws` and an
`AsyncThrowingStream` (see `ios/`).

Underneath, the generated `Mobile` class is the callback-free escape hatch:
`start(configJson)` (synchronous, blocks until serving), JSON-bytes verbs that
throw, `subscribe(req)` returning a pull-`Subscription`, and scalar shortcuts
(`confirmedBalanceSat()`, `walletReady()`). `docs/architecture.md` explains the
design; the full method list is in wavelength's
[`docs/wavewalletdk_mobile.md`](https://github.com/lightninglabs/wavelength/blob/main/docs/wavewalletdk_mobile.md).

## Documentation

- [`docs/api-guide.md`](docs/api-guide.md) — common operations as a cookbook,
  with Kotlin and Swift side by side (boot, create/unlock, sync, balance,
  activity stream, errors).
- [`docs/architecture.md`](docs/architecture.md) — how the embedded wallet,
  the in-memory transport, and the JSON boundary work.
- [`docs/android.md`](docs/android.md) — the Android build and run workflow in
  detail, including the `android` CLI and emulator.
- [`docs/signet.md`](docs/signet.md) — pointing the wallet at a signet
  environment and watching it sync.
- [`ios/README.md`](ios/README.md) — the Swift `WalletKit` wrapper and how to
  build its `xcframework`.
- [`docs/release_branch_management.md`](docs/release_branch_management.md) — the
  trunk-based release model, `v0.1.x-branch` release branches, and tagging with
  `scripts/tag-release.sh`.
- [`docs/backport-workflow.md`](docs/backport-workflow.md) — automated backport
  of merged `main` PRs to release branches via `backport-v*` labels.
