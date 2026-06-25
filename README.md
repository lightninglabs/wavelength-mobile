# damobile

Mobile host samples and (soon) idiomatic Kotlin/Swift wrappers for the
[darepo-client](https://github.com/lightninglabs/darepo-client) wallet SDK,
which embeds a full `darepod` wallet daemon in-process via `gomobile bind`.

The gomobile-safe Go facade and the `.aar` / `.xcframework` build scaffolding
live in **darepo-client** (`sdk/walletdk/mobile`, `make mobile-android` /
`mobile-ios`). This repo consumes those bindings and shows how to drive them
from a real app.

## Layout

| Path | What |
|------|------|
| `android/` | Sample Android app (Compose, AGP 9) that boots the embedded wallet and calls the bindings. |
| `scripts/fetch-aar.sh` | Builds `Walletdk.aar` from a sibling `darepo-client` checkout and drops it into `android/app/libs`. |
| `docs/` | Host-integration notes. |

Coming next: an idiomatic Kotlin (coroutines/`Flow`) and Swift
(`async`/`AsyncStream`) wrapper layer that the sample apps consume directly,
plus an iOS sample.

## Quick start (Android)

Prerequisites: a `darepo-client` checkout next to this repo, the Android SDK +
NDK (the `android` CLI installs them), and a modern JDK (17+).

```bash
# 1. Build the bindings from darepo-client and stage them here.
#    (override the location with DAREPO_CLIENT_DIR=/path/to/darepo-client)
./scripts/fetch-aar.sh

# 2. Build the sample app.
cd android && ./gradlew :app:assembleDebug

# 3. Run it on an emulator or device.
android emulator start medium_phone        # if not already running
android run --apks=app/build/outputs/apk/debug/app-debug.apk
```

The `.aar` is large (100MB+) and is **not** committed — `fetch-aar.sh`
regenerates it.

## Signet

The sample boots the embedded wallet against signet using a lightweight
Esplora-backed wallet (`lwwallet`). Configure the endpoints in
`android/app/src/main/java/.../ui/main/WalletDemoScreen.kt` (`SIGNET_CONFIG`):
the Esplora REST URL drives chain sync, and the Ark operator address is needed
for rounds/sends. See `docs/signet.md`.
