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

Set these in
`android/app/src/main/java/com/example/walletdksample/ui/main/WalletDemoScreen.kt`:

| Const | Meaning | Default |
|-------|---------|---------|
| `ESPLORA_URL` | Esplora REST base URL for signet | `https://mempool.space/signet/api` |
| `OPERATOR_ADDRESS` | Ark operator mailbox `host:port` | empty (sends disabled) |

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
