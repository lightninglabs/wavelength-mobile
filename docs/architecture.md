# Architecture

This document explains what runs where when a mobile app uses the walletdk
bindings, and why the API looks the way it does.

## The wallet runs inside your app

A normal `darepod` deployment is a daemon process that clients reach over a
gRPC socket. On mobile that model is awkward: an app cannot reliably keep a
sidecar process alive, and an open port is an attack surface.

Instead, the binding compiles the whole daemon into a native library and starts
it inside the app's own process. The Go SDK
(`darepo-client/sdk/walletdk`) boots the daemon on a background goroutine and
connects to it over an in-memory transport called a `bufconn`: a gRPC channel
backed by a memory buffer rather than a TCP socket. The app's calls travel that
buffer. Nothing listens on the network, and there is no second process to
manage.

```
┌─ your app process ────────────────────────────────────┐
│  Kotlin / Swift                                        │
│      │  Mobile.getInfo()  (JNI / cgo)                  │
│      ▼                                                 │
│  walletdk/mobile facade ──bufconn (in-memory gRPC)──┐  │
│                                                     ▼  │
│                         embedded darepod daemon ───────│
│                         (wallet, SQLite, Ark, swaps)   │
└───────────────────────────────────────────────────────┘
```

## Why a thin facade, and what it hides

`gomobile bind` carries only a narrow set of types across the boundary between
Go and Kotlin/Swift: signed integers, floats, strings, booleans, byte slices,
and interfaces or structs built from those. It cannot carry a `context.Context`,
a channel, a map, an unsigned integer, a `time.Time`, a slice of structs, or a
tagged union.

The walletdk SDK's own API uses all of those. So `walletdk/mobile` is a thin
translation layer that presents a flat, gomobile-safe surface and converts at
the edge. The app never sees the rich Go types directly.

## The JSON boundary

RPC verbs pass JSON bytes in and JSON bytes out. The host encodes a request to
JSON, the facade decodes it into the matching Go request, calls the SDK, and
encodes the response back to JSON. The host decodes the result with whatever it
already has (`kotlinx.serialization` on Android, `Codable` on iOS), so neither
platform needs a protobuf runtime.

A few hot paths skip JSON and return a plain scalar, because asking for a single
number should not require a decoder: `confirmedBalanceSat()` returns a `Long`,
`walletReady()` returns a `Boolean`.

## No callbacks

The bindings are callback-free, which is the main way they differ from
lnd-mobile. lnd must hand work to a host-implemented callback because
`lnd.Main` never returns. walletdk's `Start` returns as soon as the daemon's
gRPC channel is serving, so the binding can be synchronous instead:

- **`start(configJson)`** blocks until the daemon is serving, then returns. Run
  it on a background thread; on Kotlin that is `withContext(Dispatchers.IO)`.
- **Unary verbs** are ordinary throwing calls. A Go error becomes a thrown
  exception, which maps to Kotlin `try`/`catch` and Swift `throws`.
- **Streaming** uses a pull handle. `subscribe(req)` returns a `Subscription`;
  the host calls `next()` in a loop and `close()` to stop. This maps directly
  onto a Kotlin `Flow` or a Swift `AsyncStream`, and the host owns the thread
  the loop runs on.

The host implements no interfaces. The threading lives where the platform's
concurrency tools already are.

## Lifecycle and the singleton

One daemon runs per process. `start` is guarded by a compare-and-swap: a second
`start` before `stop` returns an error rather than booting a second daemon.
`stop` tears the daemon down, cancels an internal context that unblocks any
in-flight `next()`, and resets the guard so the app can start again after the
operating system suspends and resumes it.

A panic inside the Go code would otherwise kill the whole app, since panics do
not cross the JNI boundary. The facade recovers panics in `start` and in
`Subscription.next` and turns them into ordinary errors.

## Build tags

The facade compiles only under three Go build tags together: `mobile`,
`walletdkrpc`, and `swapruntime`. The first selects the mobile facade; the
other two pull in the embedded wallet RPC runtime and the swap executor, both of
which the embedded wallet requires. `gomobile bind` passes all three.
