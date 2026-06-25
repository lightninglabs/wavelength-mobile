# iOS — WalletKit

`WalletKit` is the idiomatic Swift wrapper over the gomobile bindings: an
`actor`-based `WalletClient` with `async`/`throws` methods, an
`AsyncThrowingStream` for wallet activity, and `Codable` models. It mirrors the
Kotlin `walletkit` library.

Building requires the `Walletdk.xcframework`, which is produced from
darepo-client (`make mobile-ios`) and is not committed here.

Verified end to end on the iOS Simulator: the Swift wrapper boots the embedded
daemon, creates a wallet, connects to the signet operator mailbox, and syncs to
the chain tip (`operator=connected`, `state=ready`).

> Linker note: the embedded daemon's Go networking references `res_9_*` symbols
> from **libresolv**, so the app target links `-lresolv` (set in
> `Sample/project.yml`). Without it the link fails with "Undefined symbols
> _res_9_ninit / _nclose / _nsearch".

## Run the sample (command line, no Xcode GUI)

```bash
# One time: a simulator runtime (the SDK ships with Xcode; the runtime is a
# separate download) and the project generator.
xcodebuild -downloadPlatform iOS
brew install xcodegen

# Build the bindings, generate the project, build, install, and launch.
./scripts/run-ios-sample.sh

# Then drive the simulator like the Android emulator:
xcrun simctl io booted screenshot ui.png

# Or run headless (no taps): autostart boots + creates a wallet on launch.
SIMCTL_CHILD_WALLETDK_AUTOSTART=1 \
  xcrun simctl launch booted engineering.lightning.walletdk.sample
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
  Package.swift                 SwiftPM package; binaryTarget -> Walletdk.xcframework
  Sources/WalletKit/
    Bindings.swift              the only file that touches generated symbols
    WalletClient.swift          actor: async/throws API + AsyncThrowingStream
    WalletConfig.swift          Encodable config + signet() factory
    Models.swift                Codable result models
  Frameworks/                   Walletdk.xcframework goes here (gitignored)
```

## Build the framework

```bash
# From a darepo-client checkout. Produces sdk/walletdk/mobile/build/ios/Walletdk.xcframework
make mobile-ios

# Stage it into the package (or run scripts/fetch-xcframework.sh):
mkdir -p ios/WalletKit/Frameworks
cp -R /path/to/darepo-client/sdk/walletdk/mobile/build/ios/Walletdk.xcframework \
      ios/WalletKit/Frameworks/
```

`make mobile-ios` runs on macOS with Xcode installed and cross-compiles the
embedded daemon for device + simulator slices.

## The generated symbol prefix

gomobile names the generated free functions after the Go package, so they are
`MobileStart`, `MobileGetInfo`, `MobileSubscribe`, and a `MobileSubscription`
class, all in a `Walletdk` module. Every reference to those symbols lives in
`Bindings.swift`; if the prefix changes (the `gomobile bind -prefix` flag in
`gen_bindings.sh`), that one file is the only edit.

## Usage

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
