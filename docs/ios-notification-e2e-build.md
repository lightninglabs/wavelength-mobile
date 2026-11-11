# Preparing a notification test build

Build the existing app and pinned native SDK for a physical iPhone without
changing the ordinary app configuration. This preparation never signs,
installs, uploads or provisions an app. Its output is an unsigned `.app`, a
build log, an isolated Xcode project and `build-manifest.json` with the source,
native pin, bridge digest, Apple environment and completion state.

Use an untracked local JSON file for publisher configuration. It contains
`origin`, `appAlias`, `swapIssuer` and a boolean `receiptHints`.
Use the verified publisher origin and service public key. No device token,
capability or Apple provider key belongs in this file. The app understands
`receiptHints` as a string in its plist; the build converts the JSON boolean.
Only the signet network receives this notification configuration. The wallet's
normal network selector remains available.

```sh
python3 scripts/build-ios-notification-e2e.py \
  --output /absolute/path/outside/this/checkout \
  --bundle-id your.existing.wallet.identity \
  --relay-config /absolute/path/to/untracked-publisher.json
```

Release is the default. Its APNs and App Attest entitlements select production,
as TestFlight requires even for a Bitcoin signet wallet. `--configuration Debug`
selects development for both Apple services. The relay's publisher policy must
match the final signed app, distribution channel and alias. A development alias
must remain separate from a TestFlight alias.

If the real publisher configuration is not ready, use `--without-relay` instead
of `--relay-config`. The result compiles but cannot test notification delivery.
`--prepare-only` generates the isolated project/plist without building. All
output must be in a new directory outside this checkout. The checked-in
publisher dictionary remains empty.

Unsigned builds are compile evidence. They cannot be installed via TestFlight,
enroll with App Attest or receive APNs. To test through TestFlight, use a profile
that includes Push Notifications and App Attest, archive this generated project
with the publisher plist, verify the signed application's identifier and
production entitlements, then follow the publisher's existing upload workflow.
Rebuilding the ordinary project would discard this generated configuration.
Keep source and native provenance with the signed archive. Use a fresh build
number and confirm it is available to the intended internal group.

After an authorized relay/producer rollout, test a real signet payment through
source event -> relay -> APNs -> device callback -> verified local receipt ->
notification -> Activity tap. Also test round/refresh opportunities, duplicate
hints, foreground takeover, locked-wallet fallback and revoked grants. A relay
acceptance or a successful simulator test alone proves no device delivery.

Local build-tool checks:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_notification_e2e.py'
```
