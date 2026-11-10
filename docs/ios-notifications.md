# iOS payment activity notifications

The app supports optional payment-activity alerts, verified receipt amounts and
local Activity navigation. Valid relay pushes and scheduled background tasks
attempt native round and refresh work on a retained runtime or a cold wallet
with a device-managed credential.
A push remains a hint; only local wallet proof can supply a received amount.

## Publisher configuration

`ios/Sample/project.yml` owns the generated `NotificationInfo.plist` and
`Wavelength.entitlements`. `WavelengthNotificationRelays` is empty by default.
Before a release, add a dictionary for each supported Bitcoin network with:

| Key | Meaning |
| --- | --- |
| `origin` | Fixed HTTPS relay origin without a path or credentials |
| `appAlias` | Publisher alias configured on the relay |
| `producerAlias` | Relay allowlist alias configured on both producers |
| `swapIssuer` | Compressed 33-byte public key of the trusted swap service |

These are build configuration, never fields from a notification. Custom
operator or swap endpoint overrides disable new enrollment. Original relay
configuration stays with local route metadata so old grants remain revocable.
No secret APNs key belongs in the app.

Debug prepares development APNs and App Attest entitlements. Release prepares
production entitlements, including TestFlight. These environments are separate
from the Bitcoin network. The Apple application identifier, provisioning profile,
relay audience and relay APNs policy must agree. This source change does not
modify Apple portal capabilities or provision a profile.

## Owners and execution

- `WalletNotificationDelegate` receives APNs tokens and system notification
  callbacks and retains their completion lease until return or system expiry.
- `NotificationRelayClient` serializes complete App Attest operations across
  network awaits. It stores installation identity and grants in device-only
  Keychain, separately from wallet secrets. It rejects redirects.
- `WalletNotifications` owns per-network consent and local route metadata. It
  retries setup and revocation on foreground entry. Grant expiry is renewed
  within its last day. Relay revocation invalidates both wake and alert authority;
  the producer's bounded expired/revoked subscription cleanup is independent.
- `WalletStore` owns native source registration. The normal operation-admission
  gate prevents a network switch while the wallet signs the registration.

Enrollment persists the pending key and deterministic installation ID first.
After a lost response, the next client probes that ID before re-attesting.
Persist relay grants before binding them to producers. The operator receives
wake authority only; the swap service may receive generic alert authority.
Apple's specific `invalidKey` error replaces an installation after reinstall.
The app retains old subscription IDs and removes still-live bindings with the
matching wallet's signature before binding the new grant. A transport failure
or HTTP 401 never resets a confirmed installation. If the old wallet cannot
sign removal, a destroyed Apple key cannot revoke that installation's grants;
the app retains metadata and reports their expiry instead of claiming they
were revoked. Old queued hints may still arrive during their bounded lifetime.

Neither producer receives Apple credentials, wallet keys, notification amounts or a URL
chosen by the push. An HTTP 401 does not establish successful revocation.

Route IDs are deterministic hashes of publisher scope, network, wallet identity
and source. A restored wallet reconstructs the same route after reinstall even
when UserDefaults was removed. A different wallet or network cannot inherit it.

A tap resolves a known local opaque route, waits for the matching network and
unlocked wallet, refreshes wallet activity and opens Activity. Unknown routes
are ignored. Cross-network taps ask the user to open that network. They never
switch an active payment's network automatically. Push event hashes, amounts
and external links cannot choose navigation targets or authorize a payment.

## Verified receipts and background maintenance

Simulator unit tests inject an attester and HTTP fixture. They do not disable
App Attest in the production client or relay. Real enrollment and push delivery
require a physical supported device and separately provisioned infrastructure.

The app always enables the durable native round runtime. Notification consent
does not disable that runtime after adoption. Background entry pauses mailbox
intake after state-creating calls finish. The daemon, domain actors, swap workers,
egress and database stay retained. Foreground entry cancels and joins any bounded
window before resuming continuous ingress or considering a transport restart.

`WalletBackgroundMaintenance` registers a `BGAppRefreshTask` at launch and
resubmits at launch, background entry and task handling. The request's earliest
begin date is fifteen minutes away; iOS chooses actual timing. Both scheduled
tasks and known current relay routes may prepare the selected device-managed
wallet, then attempt a fifteen-second native maintenance window. Startup leaves
mailbox intake paused. Missing or unmigrated credentials skip the opportunity;
background execution never prompts, creates wallets or grants UI access. The
native runtime samples chain height, applies existing expiry policy to a bounded
page of existing VTXO owners and pumps native round events. Retained signing
sessions can advance; cold startup must recover from durable state and cannot
restore lost in-memory signing sessions. The outer twenty-second deadline covers
preparation too. The UI lock still gates interaction; notification amount consent
and verified source proof independently control amount presentation.

The project declares `fetch`, `remote-notification` and the exact permitted task
identifier `engineering.lightning.wavelength.wallet.maintenance`. System expiry
and a twenty-second outer timer finish OS callbacks exactly once, signal the
matching unique native window and retain the original native owner until its
actual return. During cold preparation, expiration cancels and joins only the
runtime started by that preparation. Expiration of an established window never
stops a retained wallet or opens a second owner.

The optional publisher build key `receiptHints: "true"` enables the separate
"Show received amounts" setting. It is off by default. The updated consent
explicitly covers locked-app amounts; old consent does not enable this mode.
Opt-in creates a fresh
consent epoch. Only new successful local invoice admissions with typed source
references are enrolled. Timed-out invoice recovery cannot enroll an old invoice.
The app requires the relay's explicit `receipt_hint` acknowledgement before
selecting silent payment hints instead of generic remote alerts.

A `payment_activity` hint contains an opaque correlator, never an amount. The app
matches it to a current route and enrolled invoice, then runs a bounded targeted
receipt window. Only complete matching local source/canonical proof with the
original principal can show "You received X sats", including while the app is
locked. A consent/account change,
timeout or incomplete proof removes amount authority. A valid payment hint may
instead show fixed generic activity text. Ordinary wake messages, foreground hints and already
visible remote alerts never create another local banner. Per-event presentation ownership leaves
a duplicate hint unclaimed so it cannot downgrade the first callback. An
unrelated native window still permits a generic banner for another event. Known
subscribed routes for another saved network retain generic presentation; amount
work remains restricted to the current matching wallet and configuration. A device-only Keychain
ledger claims the event before notification insertion, preventing later replay
from duplicating a generic banner as an amount banner. Failed insertion may omit
a banner; wallet activity remains authoritative. Taps use the existing local
route and authentication flow.

The correlator is deterministic and unkeyed. A relay that already knows a
candidate wallet identity and invoice hash can confirm the link. Treat the relay
as the app publisher's trusted processor. Coalescing and deduplication can omit
individual invoice hints. Push delivery and scheduled tasks do not guarantee a
wake before a round deadline, refresh completion or expiry protection.

Simulator tests exercise the actual pinned native framework, optional receipt
metadata, route parsing, explicit mode acknowledgement, mode-sensitive caching,
consent epochs, proof matching, durable presentation deduplication, cold
device-managed startup, missing-credential refusal, cancelled startup, foreground
takeover and exact-once expiration completion. They do not prove physical-device
APNs delivery or App Attest provisioning. Publisher configuration remains empty;
this PR changes no Apple portal state and deploys no service.
