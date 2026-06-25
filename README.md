# damobile

Run a self-custodial Ark wallet inside a mobile app, with no separate daemon
process and no open network port.

`damobile` holds the host-side samples and (soon) the idiomatic Kotlin and
Swift wrappers for the [darepo-client](https://github.com/lightninglabs/darepo-client)
wallet SDK. That SDK embeds a full `darepod` wallet and exposes it to mobile
through [`gomobile`](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile). The
wallet runs in the app's own process; the app calls it across a private
in-memory gRPC channel, so nothing ever listens on a socket.

## How the pieces fit

```
darepo-client/sdk/walletdk/mobile   gomobile-safe Go facade over the embedded daemon
            │  gomobile bind
            ▼
   Walletdk.aar  /  Walletdk.xcframework   daemon compiled to a native lib
            │                              + generated Kotlin / Swift classes
            ▼
   damobile/android  (this repo)     sample app that links the lib and calls it
```

The Go facade and the binding build live in **darepo-client**
(`sdk/walletdk/mobile`, `make mobile-android` / `mobile-ios`). This repo
consumes the bindings and shows an app driving them end to end: boot the
embedded wallet, create a key, sync the chain from Esplora, and read balances.

## Repository layout

| Path | Contents |
|------|----------|
| `android/` | Sample Android app (Jetpack Compose, AGP 9). Boots the embedded wallet and exercises the bindings. |
| `scripts/fetch-aar.sh` | Builds `Walletdk.aar` from a sibling `darepo-client` checkout and stages it under `android/app/libs`. |
| `docs/` | Architecture, the Android workflow, and signet setup. |

The next milestone adds an idiomatic wrapper layer (Kotlin coroutines /
`Flow`, Swift `async` / `AsyncStream`) and an iOS sample. The sample apps will
then call the wrappers instead of the raw generated classes.

## Quick start (Android)

You need three things:

1. A `darepo-client` checkout beside this repo (the script builds the `.aar`
   from it).
2. The Android SDK and NDK. The [`android` CLI](https://developer.android.com/tools/agents/android-cli)
   installs them: `android sdk install platform-tools emulator
   platforms/android-36 build-tools/36.1.0 ndk/29.0.14206865
   system-images/android-36/google_apis/arm64-v8a`.
3. A modern JDK (17 or newer).

```bash
# 1. Build the bindings from darepo-client and stage them here.
#    Point DAREPO_CLIENT_DIR elsewhere if your checkout is not ../darepo-client.
./scripts/fetch-aar.sh

# 2. Build the sample app.
cd android && ./gradlew :app:assembleDebug

# 3. Run it on an emulator (or a device).
android emulator start medium_phone
android run --apks=app/build/outputs/apk/debug/app-debug.apk
```

The `.aar` carries the daemon compiled for every Android ABI, so it is large
(150 MB and up). `fetch-aar.sh` regenerates it and `.gitignore` keeps it out of
the repo.

## The binding API, in one breath

The generated `Mobile` class (Java package
`engineering.lightning.walletdk.mobile`) is callback-free:

- `Mobile.start(configJson)` boots the daemon and blocks until it is serving.
  Call it off the main thread.
- The RPC verbs (`getInfo`, `balance`, `createWallet`, `list`, ...) take and
  return JSON bytes and throw on error.
- `Mobile.subscribe(req)` returns a `Subscription` whose `next()` you pull in a
  loop; `close()` ends it.
- A few hot paths return plain scalars: `confirmedBalanceSat()`,
  `walletReady()`, `isRunning()`.

`docs/architecture.md` explains the design and why it is shaped this way. The
full method list lives in darepo-client's
[`docs/walletdk_mobile.md`](https://github.com/lightninglabs/darepo-client/blob/main/docs/walletdk_mobile.md).

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — how the embedded wallet,
  the in-memory transport, and the JSON boundary work.
- [`docs/android.md`](docs/android.md) — the Android build and run workflow in
  detail, including the `android` CLI and emulator.
- [`docs/signet.md`](docs/signet.md) — pointing the wallet at a signet
  environment and watching it sync.
