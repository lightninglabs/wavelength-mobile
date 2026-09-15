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

Empty endpoint overrides in `WalletConfig.signet(...)` use the defaults compiled
into the Wavelength binding. For the pinned v0.1.2 release these are:

| Parameter | Meaning | Default |
|-----------|---------|---------|
| `esploraURL` | Esplora REST base URL | `https://mempool.space/signet/api` |
| `operatorAddress` | Ark operator mailbox `host:port` (TLS) | `signet.wavelength.lightning.finance:443` |
| `swapServerAddress` | swap server `host:port` (TLS) | `swap.signet.wavelength.lightning.finance:443` |

The operator and swap endpoints terminate TLS at `:443`, so they run secure (no
`insecure` flag). An empty `operatorAddress` uses the default operator; it does
not disable the operator connection.

The native iOS smoke test connects to these services, creates receive requests,
and recovers the original invoice after foregrounding and process relaunch.
It does not fund or settle a payment. See the [iOS integration log](ios-integration.md)
for observed results and the next funded test.

## Standard signet vs mutinynet

`waved` maps the network name `signet` to **standard** `chaincfg.SigNetParams`.
Mutinynet is a *custom* signet with its own signet challenge; pointing a
standard-signet wallet at a mutinynet Esplora will fail header validation.
Supporting mutinynet requires wiring a configurable signet challenge into
`waved` first — track this before switching the default endpoint.

## Notes

- The emulator reaches the host loopback at `10.0.2.2`; a public Esplora URL
  (like the default) works directly.
- First sync downloads a lot of headers; give it time and watch the `sync:`
  log lines.
