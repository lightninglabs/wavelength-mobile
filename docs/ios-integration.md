# iOS SDK integration checks

The WalletKit tests cover configuration and endpoint encoding, payment-request
parsing, send-credit authorization, uncertain receive outcomes, activity model
compatibility, and verified credit-funding grouping. The framework-cache tests
cover release replacement, source provenance, offline reuse, and preservation
of the installed artifact after a failed replacement.

Two live SDK probes are opt-in:

- `make test-signet` creates unfunded native wallets and verifies a small
  invoice quote, independent credit limits, and explicit opt-out. It never
  dispatches a payment.
- `make test-storage-signet` creates a temporary native wallet beside an
  app-owned SQLite transaction, closes and relocates its managed directory,
  then checks that the same wallet identity and original invoice reopen.

Dario Anongba Varela contributed the release-pinning and signet-test workflow,
expired-invoice semantics, and the native storage probe and investigation.
Their original signed history remains in
[PR #6](https://github.com/lightninglabs/wavelength-mobile/pull/6).

These SDK checks do not establish OS background wake or funded exit/recovery
settlement. Native wallet UI and funded app acceptance are a separate change.

Validation on 2026-11-06 with Xcode 26.6 / iOS 26.5: all 22 SDK tests passed,
including both opt-in live probes, with no failures or skips. Source/release
framework-cache regression tests and shell syntax checks passed. The original
diagnostic demo's source files remain unchanged from `main`.
