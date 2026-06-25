# Running the sample on signet

The embedded wallet uses the lightweight, Esplora-backed wallet (`lwwallet`),
so it needs only an Esplora REST endpoint to sync the chain — no neutrino P2P,
no full node. The Ark operator mailbox is a separate endpoint, needed only for
rounds / sends (cooperative join, leave, Lightning).

## What syncs with just Esplora

After `Start` + `CreateWallet`, the wallet begins importing block / filter
headers from `ESPLORA_URL` and the reported `BlockHeight` climbs toward the
signet tip. Balance and on-chain history work off this sync alone. The Ark
operator is **not** required for chain sync — a missing/placeholder operator
just means sends and rounds are unavailable.

## Endpoints

`WalletConfig.signet(...)` carries Lightning Labs' public signet deployment as
defaults; override any of them per call:

| Parameter | Meaning | Default |
|-----------|---------|---------|
| `esploraUrl` | Esplora REST base URL | `https://mempool.space/signet/api` |
| `operatorAddress` | Ark operator mailbox `host:port` (TLS) | `arkd-signet.testnet.lightningcluster.com:443` |
| `swapServerAddress` | swapdk-server `host:port` (TLS) | `swapd-signet.testnet.lightningcluster.com:443` |

The operator and swap endpoints terminate TLS at `:443`, so they run secure (no
`insecure` flag). Pass an empty `operatorAddress` to run sync-only without an
operator.

Verified end to end on an emulator: the embedded wallet connects to the operator
over TLS, fetches operator terms, and starts the durable mailbox ingress loop,
while the Esplora-backed wallet syncs to the signet tip.

## Standard signet vs mutinynet

`darepod` maps the network name `signet` to **standard** `chaincfg.SigNetParams`.
Mutinynet is a *custom* signet with its own signet challenge; pointing a
standard-signet wallet at a mutinynet Esplora will fail header validation.
Supporting mutinynet requires wiring a configurable signet challenge into
`darepod` first — track this before switching the default endpoint.

## Notes

- The emulator reaches the host loopback at `10.0.2.2`; a public Esplora URL
  (like the default) works directly.
- First sync downloads a lot of headers; give it time and watch the `sync:`
  log lines.
