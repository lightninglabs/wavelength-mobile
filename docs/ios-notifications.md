# iOS payment activity notifications

The app supports optional generic remote alerts and local Activity navigation.
It does not yet execute a cold wallet receive in a background callback or show
exact receipt amounts. A push reports activity, not successful settlement.

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
  callbacks. Background delivery returns `noData` and leaves the daemon untouched.
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

A tap resolves a known local opaque route, waits for the matching network and
unlocked wallet, refreshes wallet activity and opens Activity. Unknown routes
are ignored. Cross-network taps ask the user to open that network. They never
switch an active payment's network automatically. Push event hashes, amounts
and external links cannot choose navigation targets or authorize a payment.

## Validation and remaining runtime work

Simulator unit tests inject an attester and HTTP fixture. They do not disable
App Attest in the production client or relay. Real enrollment and push delivery
require a physical supported device and separately provisioned infrastructure.

The current native source pin provides signed source subscriptions and retained
shutdown ownership. Exact “received X sats” alerts require canonical completed
receipt reconciliation, durable notification deduplication and a bounded host
execution window. None is inferred from an empty mailbox, `isRunning == false`,
or an advisory remote hint. Biometric user-presence protection remains in force.
