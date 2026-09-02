# Cooperative cancellation between citadel source operations

## Boundary

Follow-up to the owned site queue (`be3929d`) on `codex/citadel-visuals-clean`.
This is an intermediate source-only prerequisite, not live integration. The
queue's real first run measured 232.534 seconds between structural completion
callbacks. No running worker may be destroyed merely because its result was
fenced off by cancellation.

An optional continuation now travels separately from serialized source policy:
ordinary source composer -> structural completion -> facade completion ->
opening heads and lower bearings. Existing callers may omit it. Returning true
continues; the first other value aborts the private transaction with
`ready: false, reason: cancelled`. No partial source snapshot, furnishing plan,
terminal proof or successful completion is returned on this path. The existing
policy-based opening-head progress notification retains its old ignored-return
behavior; it is not repurposed as cancellation control.

Checks surround house proposals, facade-bottom proposals and their major proofs,
later structural stages and individual repair proposals. Cancellation passes
through failure wrappers, and the composer does not emit a construction error
for an explicitly cancelled request. Genuine construction failures retain their
existing classification. Geometry operations, ordering, input policy, RNG and
successful output schema are unchanged.

## Verification status

The independent critic approved this intermediate design, not live dispatch.
All artifacts below are under `artifacts/citadel-runtime-integration/`. Exact
commands, engine, process membership and exit evidence are in each watchdog
report. All launches are headless; no headed approval is requested or implied.

- `site-build-queue-real-02`: actual Queue -> Site -> Source, `atlas-1492`,
  region `(1,-3)`, scale 1.25. Passes 8/8 in 319.135 seconds. The complete
  authoritative result remains byte-exact against `actual-site-source-05`,
  excluding only root `preparationUsec` and the same six survey scheduling/timing
  fields documented in the queue report. No geometry, furniture, reservation,
  manifest or source identity fields are exempt. Output SHA256:
  `f6e55e1b12a3d3d32ecea6554d47230efc66bfaca40c804e3c1eedd8a5c7eff0`.
  15,409 polls; internal poll maximum 80 microseconds; immutable consumed-once
  result and joined shutdown. Source/input hashes stay stable.
- `site-structural-cancel-01`: actual threaded source with observation-only
  capture of Site's return; no substituted construction, delay, semaphore hold
  or forced termination. Requests cancellation during
  `lower_facade_initial_proof_started`. Passes 8/8: Site itself returns
  `cancelled`, including Source's sanitized cancelled result, without blueprint
  or furnishings. Queue consumes cancellation once and drains worker/retirement.
  Request call 8 microseconds, external whole-poll maximum 268 microseconds;
  request-to-source-join/result is **7.921255 seconds**. This is still too slow
  for live shutdown acceptance. Exact request is recorded at engine usec
  88501149, Site return at 96417779, source join observed at 96422404.
  Stdout observes the first rejecting checkpoint
  `lower_facade_initial_proof_completed` at elapsed 94575061 usec; this is a
  poll-observed upper bound, not an exact callback invocation timestamp.
- `site-build-queue-contract-03`: existing synthetic queue contracts still
  pass 206/206 with current dependencies; max internal poll 89 microseconds.

These runs have natural exit 0, clean logs and authoritative zero owned
processes. The real preservation and cancellation runs overlapped headlessly;
timings are observations, not isolated performance benchmarks. Recorded
structural progress intervals now peak at 16.974 seconds (the lower-facade final
verification) rather than the former single 232.534-second structural interval.
Fast intermediate stages may fall between polls. Repeated identical survey
callbacks are not written as stage changes, so a long same-label survey interval
must not be interpreted as missing cancellation checkpoints. The unchanged
initial compound still has an observed 42.561-second progress gap.

The nested API contract uses two explicit evidence levels: cancellation against
hash-bound archived source geometry (fixture-only producer metadata restored),
and successful equality on two houses built by the real street-house recipe.
It does not substitute test geometry for a live whole-citadel acceptance run.
The first parity attempt correctly failed because its fixture supplied a
non-masonry material; the fixture now uses the production masonry material.
No success assertion or source rule was weakened. `completion-parity-01` retains
that failure with natural exit 1 and owned zero.

Final reusable-wrapper runs pass with current script/wrapper hashes and clean
owned-process exit:

- `completion-cancel-03`: 84/84, 31.638 seconds. All five API entries, actual
  per-house/per-panel cancellation, later-stage cancellation, first-false
  termination, input bytes/object aliases and absence of publishable output.
- `completion-parity-03`: 61/61, 33.153 seconds. Omitted, explicitly empty and
  always-true continuation produce successful byte-exact complete results on
  all five APIs, including diagnostics. Final-precommit cancellation, genuine
  failure classification and false/void legacy observer semantics also pass.

Reproduction from the project root (fresh output paths required):

```powershell
./tools/run-citadel-completion-cancellation-contract.ps1 -Phase cancellation -OutputDirectory artifacts/citadel-runtime-integration/completion-cancel-03 -AuthorizeLaunch -TimeoutSeconds 60
./tools/run-citadel-completion-cancellation-contract.ps1 -Phase parity -OutputDirectory artifacts/citadel-runtime-integration/completion-parity-03 -AuthorizeLaunch -TimeoutSeconds 60
```

Cancellation replay requires the hash-bound archived fixture identified in the
runner/report; it is not silently regenerated. The wrapper derives the current
project root, records branch/commit/source identity and retains fresh-output
containment plus the process-owning watchdog. It is not fixed to this machine's
worktree or branch name.

The independent critic approved the focused intermediate commit after inspecting
the final cancellation03/parity03 reports, current hashes, clean process exits,
production patch, real preservation/cancellation evidence and queue regression.
There were no blocking findings. Approval excludes live dispatch, bounded
shutdown, headed testing and goal completion; deep proof/compound cancellation
is the next prerequisite.

## Remaining work

These are operation checkpoints, not interruption inside an operation. Physical
validation, initial compound construction, other source stages and cleanup can
still take seconds between checks. Measure these separately and add deep
cooperative cancellation before enabling a live caller. This patch does not
claim a hard shutdown latency, faster total source construction, streaming
readiness, terrain admission, player traversal or visual acceptance.

Native terrain admission and ordinary structure/tree/door publication remain
unfinished. Existing NPC baseline failures stay deferred by the user's explicit
decision; no protected pathfinding code is changed.
