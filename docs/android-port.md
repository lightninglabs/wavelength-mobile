# Android wallet port

The Android app uses Kotlin and Jetpack Compose over the same embedded Go wallet
as iOS. The visual reference is the current iOS wallet in this repository. Keep
its Signal Dark and Porcelain Light palette, wave artwork, spacing, amount
hierarchy, labels and progressive disclosure. Use native Android authentication,
permissions, navigation, sharing and accessibility behavior.

## First milestone: a real Signet wallet

The first three PRs are a linear stack:

1. **SDK alignment:** exact native pin and bridge provenance, typed activity and
   credit fields, bounded receive requests and foreground ownership.
2. **Wallet foundation:** device-bound encrypted credentials, creation/restore,
   authenticated reopening, asynchronous balance/activity, backup and connections.
3. **Payments:** Lightning quote/confirm, invoice and on-chain receive QR, durable
   uncertain-operation tracking, and emulator Signet payment validation.

This milestone intentionally exposes Signet only. No mainnet controls or
placeholder buttons suggest that unfinished flows work. There is no Android push
enrollment or background scheduler yet. Foreground ingress stops when the app
leaves the foreground. Native payment records and unresolved host evidence stay
on disk; returning to the app resumes observation rather than redispatching.

Use `./scripts/fetch-aar.sh --if-needed`, then build with Gradle. A local ARM64
emulator build can use:

```bash
cd android
./gradlew -PwalletAbis=arm64-v8a :app:assembleDebug :app:testDebugUnitTest :app:lintDebug :walletkit:testDebugUnitTest
```

Omitting `walletAbis` includes every ABI in the native AAR. The debug APK is at
`app/build/outputs/apk/debug/app-debug.apk`. Debug builds permit screenshots for
visual validation. Release builds prevent screen capture. Credentials and wallet
state are stored under `noBackupFilesDir`; never uninstall or clear app data to
update an existing wallet.

## Instrumented UI tests

Run `connectedDebugAndroidTest` only on a separate disposable emulator. The
Android Gradle test runner defaults to `uninstall_after_test: true` for the target
app as well as the test APK. That removes its wallet database and device-bound
credentials. The normal build, JVM tests and lint commands above do not install
or uninstall the app. Use `adb install -r` for wallet-preserving APK updates.

The field regression test checks that a complete invoice survives input, theme
recomposition and replacement. Real Signet payment checks use the ordinary app
screens, with settlement verified independently on the receiving Lightning node.

## Remaining screen parity

Port each area in a separate, reviewable slice. Compare both appearances against
the corresponding SwiftUI screen, including loading, empty, pending, success and
failure states. Do not replace these with generic dashboards.

| Area | iOS reference | Required behavior |
| --- | --- | --- |
| Network wallets and connections | `SettingsView`, `Components`, `WalletAuthentication` | Per-network isolation, effective defaults, consistent authentication and tidy network selection. |
| Payment completion | `SendView`, `ReceiveView`, `ActivityViews` | Camera/BIP-21 handling, on-chain sends, options, payment details, matched credit funding details, copy/share and ordinary QR codes. |
| Exits and recovery | `CooperativeExitView`, `RecoveryViews` | Destination and fee order, safe selection, accepted/unknown results, unilateral plans, sweeps and exports. Batch exit follows the corresponding merged SDK/app contract. |
| Expert inventory | `DiagnosticVTXOsView`, `DiagnosticVTXODetailView` | Out-of-round/confirmed status, expiry, copyable underlying UTXOs, raw JSON under Advanced. |
| Refresh visualization | `DiagnosticWindowViews`, `DiagnosticRoundsView` | Same timing bars, selected-round boundaries, due/not-due states and navigation affordances. |
| Transfers | `DiagnosticTransfersView` | Direction, amount, status and useful details. |
| On-device logs | `DiagnosticLogsView` | Bounded buffer, case-insensitive literal filtering, explicit follow/pause, and no scroll jump while reading older lines. |
| Background runs | `DiagnosticBackgroundView` | Connected stage timeline, durations, outcome and error details. |
| Notifications and background work | `WalletNotifications`, `NotificationRelay`, `WalletBackgroundMaintenance` | Android-specific relay enrollment and FCM delivery, bounded work, durable outcomes and physical-device wakeup evidence. |

WorkManager or FCM delivery is not proof that a round completed. Validate native
startup, receipt processing, quote/round transitions and visible activity
separately. Never automatically resubmit a payment because its response was lost.

## Distribution

A directly installed APK can use FCM after Android enrollment is implemented.
Google Play internal testing is an optional distribution channel, not a push
notification prerequisite. Emulator testing uses a Google APIs/Play image.
Physical-device notification and hardware-backed authentication checks remain
separate from emulator payment evidence.
