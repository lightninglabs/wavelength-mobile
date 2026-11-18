# Background traces on iOS and Android

Diagnostics → Background lists host execution opportunities. Open a run for its
wake context, measured startup, native work summary, connected timeline, raw
trace export and related logs. The trace is diagnostic evidence, not a wake
scheduler or proof that refresh or a round completed.

On iOS, open the refresh from Wallet Activity to see its current confirmed,
available and unresolved inputs. Open Diagnostics → Rounds to inspect the
wallet's active and recorded rounds. These read current native wallet state.

A refresh can settle across several rounds. The app keeps the original selection
and reports partial settlement instead of leaving it permanently in progress.
An explicit review can select only the remaining available inputs. The observer
requires positive confirmed or live evidence for every original input and no
nonterminal round, including temporary registrations, before allowing another
review or releasing the known-refresh network-switch guard. Missing records,
unconfirmed settlement, active rounds and read failures remain unresolved.
This guard does not certify that every unrelated native obligation can stop.

The refresh screen checks automatically and supports pull-to-refresh. Failed
status reads remain visible and preserve the saved operation. Reading status
does not queue a refresh or replay a join.

## What the app knows

| Observation | Source |
| --- | --- |
| Scheduled refresh, known relay wake, payment hint or unrecognized push | The host callback and validated local route classification. |
| Scheduled round, round signing or mailbox update | Optional diagnostic metadata on a known relay route. Legacy relay wakes have an unavailable reason. |
| iOS entry point and task identifier | `BGAppRefreshTask` or the APNs background callback. |
| Android entry point, request ID and retry attempt | The executing WorkManager request. Attempts are displayed starting at one. |
| Cold or retained startup | The existing runtime branch, without another native query. |
| Credential read, daemon startup, wallet unlock, ingress pause and preparation duration | Timed calls the host already makes. A stage not reached stays unrecorded. |
| Native window duration and configured host/native budgets | Existing invocation and host policy, not the remaining OS execution allowance. |
| Mailbox batches, VTXO owners checked, deferred/more work, foreground requirement and interruption/budget flags | The returned native result, without additional wallet RPCs. |
| Receipt proof counts | Results already returned by the targeted source reads. Counts are not independent payment or settlement totals. |
| Waiting for a native owner, foreground request, expiry, native return and owner release | The corresponding host observations. |

The app cannot explain why the OS chose that delivery time, whether a silent
push was dropped before reaching the process, or what another process did.
An opaque push never supplies a receipt amount, endpoint or signing authority.
Unrecognized iOS pushes are labelled as such rather than as an authenticated
relay wake. Android production push enrollment remains gated as described in
[Android background notifications](android-background-notifications.md).

Native round IDs, output identifiers and protocol transitions remain in the
native logs when those subsystems emit them. This change does not classify
arbitrary log text into authoritative round outcomes or perform extra inventory
queries during a short execution window.

## Timing and terminal outcomes

New elapsed and span timings use a monotonic clock. Wall-clock timestamps remain
available for matching logs. Older records retain their original fields and show
unrecorded measurements as unknown. They are not retroactively assigned a cold
startup, wake source or execution budget.

The first terminal outcome stays authoritative. On iOS, OS completion can occur
before the native caller returns. Later result counters and cleanup observations
are retained without replacing the original expiry. On Android, the host records
owner release only after the existing cancellation join. A late observation can
therefore appear after the headline terminal duration.

On iOS, a callback with an observed owner wait and no native start appears under
that owner's run if it expires there. Opening it shows its own trace and stop
reason. A waiter that acquires the owner keeps its own history row. An unavailable
wake route has an explicit outcome. Pushes received in the foreground record a
skip in the app log outside Background's run history.

The iOS fallback covers the whole opportunity (28 seconds). Android starts its
fallback after acquiring the host owner. A relay may also report the registration
cutoff or signing wake deadline, separately from these host limits.
The SDK safety ceiling applies to the native call after preparation (30 seconds).
OS expiry is the primary stop signal; either OS expiry or the host fallback
cancels that exact native window before its separate safety ceiling.
They overlap rather than add together; the OS can end an opportunity earlier.
Mailbox batches count nonempty batches whose dispatch was attempted. Empty polls
do not count, and dispatch does not prove downstream work succeeded.

## Related logs and export

“View related logs” opens an inclusive time filter from the run's first wall-clock
observation through its last retained observation. A running run has an open end.
The viewer includes host trace entries and native logs for the selected wallet.
Filtering stays literal and case-insensitive, and browsing older lines continues
to freeze the displayed buffer. Trace export includes context, timings, stages
and returned flags; it does not automatically upload anything.

Native and host log histories are bounded. A run can outlive its corresponding
native log records. Empty related logs do not prove that the daemon did no work.
Host entries remain visible if a native-log read fails. Full trace storage keeps
at most 50 runs on iOS and 32 on Android, with 64 events per run.

Trace fields contain controlled labels, OS task/request IDs and result counters.
They exclude wallet passwords, recovery words, bearer/feed tokens, raw push
payloads, invoices, preimages, payment amounts and arbitrary error text. Existing
native log redaction remains unchanged. App-private journals stay excluded from
backup. Sharing requires the ordinary explicit system share action.

## Validation

Regression checks cover old record decoding, monotonic span duration, preservation
of the first terminal outcome with late native results, failed-stage recording
without error-text capture, inclusive log boundaries and open-ended running runs.
Existing lifecycle tests continue to cover authentication gates, cold preparation,
cleanup joining and exact-window cancellation. Emulator checks use actual native
maintenance windows without deleting wallet data or submitting a new payment.
