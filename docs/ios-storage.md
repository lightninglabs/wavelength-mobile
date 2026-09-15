# Embedded storage and lifecycle investigation

Research for [EPIC #77](https://github.com/lightninglabs/wavelength-sdk/issues/77),
2026-09-15. The executable baseline is the native Swift wrapper and the published
Wavelength v0.1.2 framework. This is a proposed integration contract, not an
implemented caller-storage API.

## Recommendation

Keep managed wallet storage as the default. Let the host choose its location,
protection and lifecycle, and keep app business data in the host's existing
database. If the app needs wallet history there, reconcile a projection through
the public wallet API. Reusing the app's database for authoritative wallet state
is a separate capability that the embedded mobile API does not currently offer.

Investigate a narrow SQL store-construction boundary in the Go runtime before
designing cross-language persistence callbacks. A generic get/set adapter would
hide transaction and durability requirements that are essential to recovery.
Neither React Native nor moving the bindings to another repository removes
these constraints; both native hosts use the same embedded engine.

## What owns persistence today

With the sample's default paths, the following live under
`<dataDir>/data/<network>/`:

| Store | Contents and owner | Relevant behavior in v0.1.2 |
|---|---|---|
| `waved.db` | Daemon, Ark state, activity, ledger, actor delivery/checkpoints | Engine opens SQLite, runs its migrations, uses WAL and `synchronous=normal`; busy timeout 30 seconds |
| `swaps.db` | Swap SDK receive/pay sessions and recovery metadata | Separate connection pool and migrations; WAL, `synchronous=full`; busy timeout 5 seconds |
| `wallet.db` | btcwallet keys and backing-wallet state | Native bbolt loader owns this database; lock/open timeout 60 seconds |

Sources: [daemon construction](https://github.com/lightninglabs/wavelength/blob/v0.1.2/waved/server.go),
[daemon SQLite configuration](https://github.com/lightninglabs/wavelength/blob/v0.1.2/db/sqlite.go),
[swap store](https://github.com/lightninglabs/wavelength/blob/v0.1.2/sdk/swaps/store.go),
[native wallet loader](https://github.com/lightninglabs/wavelength/blob/v0.1.2/lwwallet/walletdb_native.go).

The daemon's actor transactions must keep state transitions, checkpoints, and
produced outgoing work atomic. Ingress durably dispatches and checkpoints before
advancing remote acknowledgement. These are more demanding contracts than
independent record writes. The three stores above do not share one transaction;
cross-store operations depend on reconciliation, which any integration must
preserve. See the [actor architecture](https://github.com/lightninglabs/wavelength/blob/v0.1.2/docs/durable_actor_architecture.md)
and [ingress implementation](https://github.com/lightninglabs/wavelength/blob/v0.1.2/serverconn/ingress.go).

The Go database package supports PostgreSQL and has a `NewStore(*sql.DB, ...)`
constructor. That does not imply that the embedded daemon accepts a host-owned
database: `initDatabase` constructs its own SQLite store. The
[mobile JSON configuration](https://github.com/lightninglabs/wavelength/blob/v0.1.2/sdk/wavewalletdk/mobile/config.go)
exposes paths, including an optional separate swap database path, but no
connection, transaction provider or storage implementation. The sample's typed
Swift configuration exposes `dataDir` and uses the default swap location.

Browser storage needs its own probe. The
[WASM wallet loader](https://github.com/lightninglabs/wavelength/blob/v0.1.2/lwwallet/walletdb_wasm.go)
uses SQL walletdb instead of native bbolt; a native relocation result does not
establish OPFS portability, browser eviction behavior or extension ownership.

## Bounded native experiment

Run `make test-storage-signet`. It runs the unit test target, including one
opt-in integration test, without launching the sample UI. The test:

1. Creates an unrelated app SQLite database and a fresh, unfunded wallet in a
   unique temporary directory. It does not use the sample app's Keychain.
2. Holds a write transaction on the app database while starting the wallet,
   generating keys and creating one unpaid invoice through `WalletClient`.
3. Awaits a serialized `Stop`, verifies all three managed stores exist, and
   moves the entire wallet directory to a new location.
4. Starts at the new path and unlocks with the original password. It requires
   the same identity, exactly one original activity ID and the exact invoice.
   It also verifies the app database's committed value and that the old wallet
   path was not recreated.
5. Stops the runtime and removes only the disposable fixture.

This checks coexistence with independent host storage and relocation after a
normal close. It does not test injecting the app's database, active backup,
power loss, database upgrades, cross-device restore or a funded operation at
every crash boundary. The funded process-recovery evidence remains in the
[integration log](ios-integration.md).

The first run exposed a readiness distinction: waiting only for `WalletReady`
allowed a receive call to fail with `indexer client not initialized` during
startup. The probe now waits for both wallet readiness and `ServerConnected`
before its single receive call. It never retries a state-creating call to probe
readiness. This is a v0.1.2 startup guard, not a permanent guarantee that the
network or every service remains available after the check.

After adding that guard, `make test-storage-signet` passed all 14 existing unit
tests and the live storage probe (15 total, no failures). The probe took
25.7 seconds; the measured idle stop took 0.024 seconds and relocation reopen,
unlock and readiness took 2.279 seconds. These are one Simulator observation,
not latency bounds. Both funded sample wallets retained their previously
verified balances and completed payment records after this isolated run.

## Contract the host needs

| Boundary | Proposed responsibility |
|---|---|
| Identity and location | Host chooses a stable wallet/network namespace and root; engine enumerates every authoritative store and any configured path outside the root |
| Ownership | One runtime owner per wallet; serialize foreground and background entry, including duplicate wake callbacks and extensions |
| Closing | A completed close barrier means all store users and handles have stopped; specify races with start, another stop and in-flight operations |
| Migrations | Engine owns wallet schemas and versions; report upgrade failures and required space; reject unsupported downgrade without mutating data |
| Durability | Explicitly state which failures a successful commit survives and when it is safe to acknowledge remote work |
| Protection and credentials | Host selects file/Keychain policy; engine reports unavailable storage or signer without silently creating a replacement wallet |
| Backup and restore | Enumerate recovery dependencies and export a consistent recovery point; do not treat copying one live SQLite file as a wallet backup |
| App integration | Expose authoritative reads and reconnect/catch-up semantics; app owns its business projection and its reconciliation transaction |

For a business projection, key rows by wallet identity, network and activity ID;
upsert current authoritative state. Treat notifications as a reason to reconcile.
Do not infer completion from delivery, an empty stream or a missing row in a
filtered/page-limited listing. The Swift stream currently has no exposed durable
resume cursor, so a host must reconcile after reconnect rather than assume its
local projection received every update. A wallet payment and an unrelated app
database write are not one atomic transaction.

### Durability needs an explicit decision

WAL with `synchronous=normal` survives an application crash but can lose recent
commits after power loss or an OS crash. `full` adds a WAL sync per commit.
These guarantees are described by [SQLite](https://sqlite.org/pragma.html#pragma_synchronous).
An app-issued pragma on a separate connection is not a policy for the engine's
connection pool. The mobile configuration currently exposes no synchronous-mode
setting; the Go daemon configuration does.

This investigation has not demonstrated wallet data loss. It has identified a
recovery requirement: test loss of the local committed tail after a remote peer
has accepted an acknowledgement or signature. Document what can be recovered
from peer status/artifacts once normal mailbox redelivery is unavailable. Do not
treat the successful process-relaunch tests as proof of power-loss durability.

### Backup and key availability are linked

The sample keeps its generated wallet password in Keychain using
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Apple documents that it is
available after the first unlock following restart and does not migrate to a
different device. A restored copy of the wallet files therefore cannot assume
that this password accompanies it. See [Apple's accessibility contract](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly).

Before claiming restore support, separately inventory recoverable key material,
on-chain history, VTXO/exit proofs, swap secrets, in-flight signing state and app
metadata. Seed-only recovery and a complete local backup are different tests.
The sample does not explicitly configure file protection or backup exclusion on
the wallet tree. Verify the effective protection of databases and new WAL files
on a physical device; Simulator cannot prove locked-device availability.

## Relationship to background execution

The funded test showed a sender waiting for its stopped receiver, then completing
after receiver relaunch. That establishes catch-up, while the host-driven pump
in [wavelength#802](https://github.com/lightninglabs/wavelength/issues/802) remains
necessary. The sample currently handles foreground restart; it registers no
background processing or remote-notification handler.

Apple makes background notifications best effort and grants a delivered update
up to 30 seconds of execution. See [Apple's background update documentation](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app).
The deadline must include startup, storage access, unlock, service readiness,
ingress, actor work, egress and cleanup. An empty ingress batch cannot imply that
the operation completed. Existing 30-second SQLite busy and 60-second bbolt
open waits deserve cancellation/lock-contention tests; they are not measured
background overruns. A fast idle `Stop` also does not establish a bounded stop
under active signing or storage contention.

## Next implementation probes

1. Define a Go storage-construction seam for the daemon SQL store. Use a
   caller-created SQL database with engine-owned migrations and explicit
   borrowed/owned connection semantics. Test rollback of checkpoint plus outbox,
   host writer contention, cancellation, close ownership and reopen. Keep the
   separate swap and key stores visible in the contract.
2. Resolve durability and backup policy before exposing that seam across the
   native ABI. Prove recovery after acknowledged work and audit migration/restore
   boundaries. This may favor managed files over a shared connection for the
   first supported integration.
3. Exercise a bounded client pump with fake wakes and a locked/unavailable signer
   before adding platform push delivery. Return actionable states such as
   awaiting peer, needs unlock, more work and transient failure. Preserve one
   cursor owner and durable progress when the budget expires.
4. Validate actual wake behavior and file/Keychain availability on a physical
   iPhone. Track OS delivery, granted runtime and protocol completion separately.

These are reviewable follow-ups. This document does not implement a generic
Core Data/Room/IndexedDB adapter, a shared database, a consistent export API or
background execution.
