# Android workflow

This walks through building and running the sample app, from a clean machine to
the wallet syncing on an emulator. It uses Google's
[`android` CLI](https://developer.android.com/tools/agents/android-cli), which
manages the SDK, emulators, and deployment from the command line.

## Install the toolchain

The `android` CLI installs SDK packages into `~/Library/Android/sdk` (macOS).
The sample targets API 36 and the bindings build against NDK r29:

```bash
android sdk install \
  platform-tools \
  emulator \
  platforms/android-36 \
  build-tools/36.1.0 \
  ndk/29.0.14206865 \
  system-images/android-36/google_apis/arm64-v8a
```

You also need a modern JDK. JDK 8 is too old to assemble the `.aar`; use 17 or
newer. `fetch-aar.sh` looks for a Homebrew `openjdk@17` if `JAVA_HOME` is unset.

## Build the bindings

The sample links `Walletdk.aar`, which is built from darepo-client rather than
checked in here. `scripts/fetch-aar.sh` runs `make mobile-android` against a
sibling checkout and copies the result into `android/app/libs`:

```bash
# Default checkout location is ../darepo-client.
./scripts/fetch-aar.sh

# Or point at an explicit checkout (for example a worktree):
DAREPO_CLIENT_DIR=/path/to/darepo-client ./scripts/fetch-aar.sh
```

The build cross-compiles the embedded daemon for all four Android ABIs
(`arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`), so the first run takes a few
minutes.

## Build the app

The `android` CLI does not build apps; Gradle does. The project is a standard
Compose app with the Kotlin DSL:

```bash
cd android
./gradlew :app:assembleDebug
# -> app/build/outputs/apk/debug/app-debug.apk
```

Because the `.aar` bundles native libraries for every ABI, the debug APK is
large. To shrink it for local iteration, restrict the ABIs in
`app/build.gradle.kts`:

```kotlin
android {
    defaultConfig {
        ndk { abiFilters += "arm64-v8a" } // emulator on Apple Silicon
    }
}
```

## Create and start an emulator

```bash
android emulator create medium_phone   # one time; uses the installed system image
android emulator start medium_phone
```

On Apple Silicon the emulator runs the `arm64-v8a` image, which matches the
`arm64-v8a` slice of the `.aar`.

## Deploy and run

```bash
android run --apks=app/build/outputs/apk/debug/app-debug.apk
```

## Watch what happens

The app boots the embedded daemon, creates a wallet, and polls `getInfo` so you
can see the block height climb as the wallet syncs. Two ways to observe it:

```bash
# Mirror the device logs (the embedded daemon logs under the GoLog tag).
adb logcat -s GoLog

# Capture the current screen.
android screen capture --output=ui.png
```

For a live, resizable mirror of the device, install
[`scrcpy`](https://github.com/Genymobile/scrcpy) (`brew install scrcpy`) and run
`scrcpy`.
