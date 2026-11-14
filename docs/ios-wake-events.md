# iOS wake events and native work

A background opportunity lets the selected wallet attempt bounded work. It does
not promise a round signature, completed refresh, or protection from expiry.
iOS owns delivery and execution time. An APNs acknowledgement proves neither.

## Entry points

| Trigger | Admission | Work and evidence |
| --- | --- | --- |
| Silent relay wake | Known, unexpired local route; selected network, wallet identity and publisher configuration; background updates enabled | Prepare the selected wallet, then run its native work window. The push supplies no invoice reference or endpoint. |
| Silent payment-activity hint | Same work admission; optional banner admission is checked separately | Native work can run with banners off. Only a locally enrolled invoice and matching source/canonical proof can authorize an amount banner. |
| Visible remote alert | Existing local route and banner preference | The system already owns presentation. No second local banner is created. |
| Scheduled refresh | Registered `BGAppRefreshTask`; background updates enabled | Attempt the selected wallet's work. The request is eligible after fifteen minutes; this is not a fifteen-minute schedule. |
| Foreground entry | Normal UI authentication and wallet selection | Join any background owner before continuous mailbox ingress resumes. This is foreground recovery, not evidence of a background wake. |
| Native scheduled-round timer | A running native process and its persisted round intent | Make the existing intent eligible. A Go timer cannot wake a suspended or terminated iOS process. |

A normal lock/background transition pauses continuous mailbox intake. It retains
the daemon, database, domain actors and workers. A delivered background callback
may also start a cold device-managed wallet without opening the UI. Missing keys,
pre-first-unlock storage, or an unmigrated credential skip that opportunity.
A user force-quit prevents ordinary background-push relaunch.

## Which mailbox events may advance

The SDK's restricted window admits the existing round join acknowledgement,
quote, batch information, signing stages, terminal/error and status messages.
It also admits the existing out-of-round package submission/finalization and
incoming-output events. Two read-only lookup responses are accepted only with
their original local request provenance. Unsupported dispatch still requires
foreground handling.

These names describe the SDK dispatch policy. They do not expand producer wake
classes or make every response a wake. Response envelopes remain durable and
acknowledgeable without independently causing a notification. Some protocol
messages named “Response” are event envelopes; the envelope kind, not a substring
in the method name, controls the producer decision.

A consumed mailbox batch proves dispatch was attempted. It does not prove the
domain actor completed its work. A quote delivery and a signature delivery are
separate stages. Match returned counters, related native logs and authoritative
wallet state before claiming a refresh completed.

## Ownership and expiry

Each callback has a unique window ID and its own OS completion lease. Native
work has one owner. A second callback waits for the first owner to return, then
uses only the time left on its own lease. It does not assume the first callback
will drain its event. Expiring a queued callback removes that waiter; expiring
an active callback signals its matching native window without releasing the
owner early. Optional receipt proof skips a busy owner so generic presentation
can finish promptly, then retains the callback's separate work opportunity.

OS expiry is the primary stop signal. The host's 28-second fallback includes
credential reads and startup. The SDK has a separate 30-second native ceiling
and a 32-batch bound. These overlap; they do not add together. Foreground
entry, cancellation and network changes must wait for final native access.

## Pending receive recovery

A successful local invoice creation also saves its typed source reference for
work recovery, independently of banner and amount preferences. The device-only
record contains network, wallet identity, source, source ID and canonical entry
ID. A Lightning source ID may itself be a payment hash. These references never
go to the relay; they are never chosen from a push. No invoice or amount is
stored in this work ledger.

A generic native work window first attempts a restricted mailbox pump, then
re-arms up to 64 locally enrolled receive sources even if that first pump needs
foreground handling. A retryable error may have stopped a worker without
finishing its source; this targeted resume gives the existing receive another
attempt. It creates no invoice or payment. The work result contains no receipts
and cannot authorize any banner or amount.

Sixty-four limits one invocation, not retained admissions. A persisted rotating
cursor visits larger sets across later opportunities. Source references remain
until positive canonical completion or a matching foreground source read proves
completion. Failed UI rows, source errors, omitted results and unknown references
do not retire an obligation. Foreground source reads use the normal native
operation gate. They are not extra RPCs inside a short background window.

Existing trusted presentation enrollments are copied once into work enrollment
without promoting any banner consent. Other legacy pending invoices may have no
typed host reference. Cold/foreground wallet startup already re-arms the native
pending rows; targeted warm recovery covers locally enrolled references only.
There is no arbitrary history backfill. A failed local enrollment write shows
that background recovery is deferred and retries while the wallet is open; it
does not turn a created invoice into an apparent failure or reissue it.

## Settings and selected-wallet limits

“Background updates” controls protocol work, including scheduled opportunities
when a relay is unavailable or custom endpoints are selected. Relay availability
still gates push enrollment and trusted push routes. “Payment notifications” separately
requests permission for visible alerts. “Show received amounts” is a further
explicit consent. Denying banner permission does not disable background work.

Preference migration preserves explicit legacy opt-outs and opt-ins. An unset
preference enables work with banners off. Turning work off revokes delivery and
cancels scheduled task requests; it does not erase pending native obligations.
Restoring work does not silently opt into amount presentation.

Only the selected wallet executes in the background. A push cannot switch
networks. Other saved networks may retain permitted generic banners, but that
is not maintenance for those wallets. Switching is refused while a locally known
refresh has unresolved ownership; a completed refresh or positive retry evidence
releases that guard. This is a narrow refresh guard, not a global safe-to-stop
predicate for every protocol operation.

## Inspecting a run

Diagnostics → Background records the host callback, cold/retained preparation,
waiting for a native owner, native call, expiry, return and owner release.
Missing stages stay unknown. Related logs use the same time interval; they do
not infer a protocol outcome from an arbitrary log string. See
[background traces](background-traces.md) for timing, privacy and export details.
