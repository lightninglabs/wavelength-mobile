# API guide: common operations

This guide walks through the operations a wallet app actually performs, with the
Kotlin and Swift code side by side. Both wrappers present the same shape: one
`WalletClient` per app, typed results, thrown errors, and wallet activity as a
stream. The Kotlin client uses `suspend` functions and a `Flow`; the Swift
client is an `actor` with `async` functions and an `AsyncThrowingStream`.

For the design behind these choices (the in-process daemon, the JSON boundary,
why there are no callbacks) see [architecture.md](architecture.md). For the full
method list see darepo-client's
[`docs/walletdk_mobile.md`](https://github.com/lightninglabs/darepo-client/blob/main/docs/walletdk_mobile.md).

## The shape in one paragraph

A `WalletClient` owns the embedded daemon. You `start` it once, `createWallet`
or `unlockWallet`, then read state (`getInfo`, `status`, `balance`), receive and
send payments, and collect the activity stream. One daemon runs per process, so
a single client serves the whole app. Every call either returns a typed value or
throws, and a blocking call runs off the main thread for you.

## 1. Create a client

Hold one instance for the app's lifetime (an Android `ViewModel` field, a Swift
`@StateObject` or a stored property).

```kotlin
// Kotlin
val client = WalletClient()
```

```swift
// Swift
let client = WalletClient()
```

## 2. Boot the wallet

`start` boots the embedded daemon and returns once its gRPC channel is serving.
It blocks while booting, so both wrappers run it off the main thread for you (the
Kotlin call suspends on `Dispatchers.IO`; the Swift `actor` hops off the main
actor). `WalletConfig.signet(...)` fills in Lightning Labs' public signet
endpoints; override `dataDir` per install.

```kotlin
// Kotlin (inside a coroutine)
client.start(WalletConfig.signet(dataDir = "${context.filesDir}/walletdk"))
```

```swift
// Swift (inside a Task)
let dir = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("walletdk").path
try await client.start(.signet(dataDir: dir))
```

Starting twice before `stop` throws rather than booting a second daemon.

## 3. Create or restore a wallet

`createWallet` with an empty mnemonic generates a fresh seed and returns the
words to back up. Pass an existing mnemonic to restore. The password encrypts
the seed on disk.

```kotlin
// Kotlin: new wallet
val res = client.createWallet(walletPassword = "my-password".toByteArray())
println("back up these words: ${res.mnemonic}")

// Kotlin: restore
client.createWallet(
    walletPassword = "my-password".toByteArray(),
    mnemonic = listOf("plunge", "disease", /* ... */),
)
```

```swift
// Swift: new wallet
let res = try await client.createWallet(
    walletPassword: Data("my-password".utf8)
)
print("back up these words: \(res.mnemonic)")

// Swift: restore
_ = try await client.createWallet(
    walletPassword: Data("my-password".utf8),
    mnemonic: ["plunge", "disease", /* ... */]
)
```

## 4. Unlock an existing wallet

On later launches the seed already exists; unlock it with the same password.

```kotlin
// Kotlin
val unlocked = client.unlockWallet("my-password".toByteArray())
```

```swift
// Swift
let unlocked = try await client.unlockWallet(
    walletPassword: Data("my-password".utf8)
)
```

## 5. Check readiness and watch sync

`getInfo` returns a snapshot: the network, the synced block height, whether the
operator mailbox is connected, and a `WalletState`. The wallet is usable for
signing once `walletState` is `READY`. Poll `getInfo` to show the height
climbing while the chain syncs.

```kotlin
// Kotlin
val info = client.getInfo()
if (info.walletReady) {
    println("synced to ${info.blockHeight}, operator: ${info.serverConnected}")
}
```

```swift
// Swift
let info = try await client.getInfo()
if info.walletReady {
    print("synced to \(info.blockHeight), operator: \(info.serverConnected)")
}
```

`WalletState` is `UNSPECIFIED`, `NONE` (no wallet yet), `LOCKED` (seed exists,
not unlocked), `SYNCING` (unlocked, catching up), or `READY`.

## 6. Read the balance

`balance` returns confirmed and pending amounts in satoshis.

```kotlin
// Kotlin
val b = client.balance()
println("confirmed ${b.confirmedSat}, inbound ${b.pendingInSat}")
```

```swift
// Swift
let b = try await client.balance()
print("confirmed \(b.confirmedSat), inbound \(b.pendingInSat)")
```

`status` bundles readiness, the balance, and the pending-activity count in one
call when you want all of it together.

## 7. Stream wallet activity

`activity` streams an `Entry` for every send, receive, deposit, and exit as it
progresses. Pass `includeExisting = true` to replay current activity first. The
stream completes on a clean end and throws on a real error. Cancelling the
collector closes the underlying subscription, so collect it inside a scope tied
to the screen's lifetime.

```kotlin
// Kotlin: collect in a coroutine scope
scope.launch {
    client.activity(includeExisting = true).collect { e ->
        println("${e.kind} ${e.amountSat} sat ${e.status}")
    }
}
```

```swift
// Swift: iterate the AsyncThrowingStream in a Task
let task = Task {
    do {
        for try await e in client.activity(includeExisting: true) {
            print("\(e.kind) \(e.amountSat) sat \(e.status)")
        }
    } catch {
        print("stream ended: \(error)")
    }
}
// task.cancel() closes the subscription.
```

## 8. Receive a payment

A wallet can be paid two ways: a Lightning invoice (off-chain, instant) or an
on-chain boarding address. Both calls return the invoice or address to show the
payer, plus the initial `Entry` that will progress on the activity stream.

Lightning invoice:

```kotlin
// Kotlin
val r = client.receiveLightning(amountSat = 10_000, memo = "coffee")
showQr(r.invoice)
```

```swift
// Swift
let r = try await client.receiveLightning(amountSat: 10_000, memo: "coffee")
showQR(r.invoice)
```

On-chain deposit address:

```kotlin
// Kotlin
val d = client.newDepositAddress()
showAddress(d.address)
```

```swift
// Swift
let d = try await client.newDepositAddress()
showAddress(d.address)
```

## 9. Send a payment

Sending is two steps so the app can show the fee before committing. `prepareSend`
returns a quote with a single-use intent id; `send` dispatches that intent. Set
exactly one of `invoice` or `onchainAddress`.

```kotlin
// Kotlin: pay a Lightning invoice, fee shown first
val quote = client.prepareSend(invoice = bolt11, maxFeeSat = 50)
if (quote.feeKnown) confirm(quote.amountSat, quote.expectedFeeSat)
val sent = client.send(quote.sendIntentId)
println("sent ${sent.actualAmountSat} sat")
```

```swift
// Swift: pay a Lightning invoice, fee shown first
let quote = try await client.prepareSend(invoice: bolt11, maxFeeSat: 50)
if quote.feeKnown { confirm(quote.amountSat, quote.expectedFeeSat) }
let sent = try await client.send(quote.sendIntentID)
print("sent \(sent.actualAmountSat) sat")
```

For an on-chain send, pass `onchainAddress` and `amountSat` instead. `sweepAll`
drains every VTXO to the address.

```kotlin
// Kotlin
val quote = client.prepareSend(onchainAddress = addr, amountSat = 25_000)
client.send(quote.sendIntentId)
```

```swift
// Swift
let quote = try await client.prepareSend(onchainAddress: addr, amountSat: 25_000)
_ = try await client.send(quote.sendIntentID)
```

When you do not need to show the fee first, `payInvoice` does both steps at once:

```kotlin
client.payInvoice(bolt11, maxFeeSat = 50)            // Kotlin
```

```swift
try await client.payInvoice(bolt11, maxFeeSat: 50)   // Swift
```

A prepared intent is single-use: if `send` fails, prepare a fresh quote before
retrying.

## 10. Be notified of incoming payments

`incomingPayments` streams receives and deposits as they arrive and settle. It
is the activity stream filtered to the credit kinds. The same `Entry` appears
first as pending and then as complete, so key any UI on `entry.id` and fire a
"you were paid" notification when its status becomes `complete`.

```kotlin
// Kotlin
scope.launch {
    client.incomingPayments().collect { e ->
        if (e.status == "complete") notify("Received ${e.amountSat} sat")
    }
}
```

```swift
// Swift
Task {
    for try await e in client.incomingPayments() {
        if e.status == "complete" { notify("Received \(e.amountSat) sat") }
    }
}
```

## 11. Shut down

`stop` tears the daemon down and cancels any open stream. It is idempotent, and
the singleton resets so you can `start` again, for example after the operating
system suspends and resumes the app.

```kotlin
client.stop()   // Kotlin
```

```swift
try await client.stop()   // Swift
```

## 12. Handle errors

A failed call throws: `WalletException` in Kotlin, `WalletError` in Swift, each
carrying the underlying message. Wrap calls the way you would any throwing API.

```kotlin
// Kotlin
try {
    client.balance()
} catch (e: WalletException) {
    showError(e.message)
}
```

```swift
// Swift
do {
    _ = try await client.balance()
} catch let e as WalletError {
    showError(e.message)
}
```

A verb called before `start` throws "not started"; a verb that needs a wallet
(such as `balance` before `createWallet`) throws `FailedPrecondition` from the
daemon.

## 13. A complete first-run flow

```kotlin
// Kotlin
suspend fun firstRun(client: WalletClient, dataDir: String) {
    client.start(WalletConfig.signet(dataDir = dataDir))
    val res = client.createWallet("my-password".toByteArray())
    saveMnemonic(res.mnemonic)
    while (!client.getInfo().walletReady) {
        delay(5_000)
    }
    val b = client.balance()
    show(b)
}
```

```swift
// Swift
func firstRun(_ client: WalletClient, dataDir: String) async throws {
    try await client.start(.signet(dataDir: dataDir))
    let res = try await client.createWallet(walletPassword: Data("my-password".utf8))
    saveMnemonic(res.mnemonic)
    while try await !client.getInfo().walletReady {
        try await Task.sleep(nanoseconds: 5_000_000_000)
    }
    let b = try await client.balance()
    show(b)
}
```

## Result types at a glance

| Type | Key fields |
|------|-----------|
| `Info` | `network`, `blockHeight`, `serverConnected`, `walletState`, `walletReady`, `identityPubKey` |
| `Balance` | `confirmedSat`, `pendingInSat`, `pendingOutSat` |
| `Status` | `ready`, `unlocked`, `network`, `balance`, `pendingCount` |
| `CreateWalletResult` | `mnemonic`, `identityPubKey`, `recoveryRan` |
| `UnlockWalletResult` | `identityPubKey` |
| `ReceiveResult` | `invoice`, `entry` |
| `DepositResult` | `address`, `entry` |
| `PrepareSendResult` | `sendIntentId`, `amountSat`, `expectedFeeSat`, `feeKnown`, `rail`, `warning` |
| `SendResult` | `entry`, `actualAmountSat` |
| `Entry` | `id`, `kind`, `status`, `amountSat`, `feeSat`, `counterparty` |

All amounts are satoshis. `kind` and `status` are lowercase strings
(`send`/`receive`/`deposit`/`exit`, `pending`/`complete`/`failed`).
