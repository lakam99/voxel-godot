# Owned site preparation queue

## Scope

Runtime integration prerequisite after `3d5952c`, not live spawning. The queue
calls the existing `CitadelSitePreparation.prepare` without introducing another
generator, tree recipe, terrain authority or NPC service. No live caller is
enabled: bounded deep source cancellation and immutable native terrain admission
are still required. The explicit existing-NPC baseline exception remains in
`CITADEL_RUNTIME_INTEGRATION.md`.

One main-thread owner submits requests, polls, consumes results and requests
shutdown. It must retain the queue and keep polling until `shutdownComplete`;
requesting cancellation is not permission to destroy a still-running worker.

## Request and result ownership

Submission copies canonical seed, region, town overrides and ordinary-structure
policy before dispatch. Input dictionaries are recursively immutable; irrelevant
town fields are omitted exactly as the existing survey does. Source identity
includes source/generation policy revisions and engine version. A separate
epoch and monotonically increasing token prevent same-seed resets from accepting
previous results.

The queue holds at most eight pending requests, one active worker and one
completed result. Duplicate pending requests coalesce and may gain priority.
Within a priority class, canonical source identity is the tie-break; after three
priority dispatches, a waiting regular request gets a turn. It is not FIFO.

Worker preparation receives no Main, scene or player reference. Progress and
cancellation use a small synchronized state object. The worker snapshots the
blueprint and furnishing plan, including access reservations, then detaches and
freezes containers once. Unsupported object/packed-buffer payloads fail closed.
Limits are 32 MiB, two million visited values and nesting depth 64. Polling
returns only small status/telemetry records, never a repeated payload copy.

Only a matching current token can consume the result, once. `prepared`, `failed`,
legitimate `absent`, and `cancelled` remain distinct. A cancelled completed result
still holds completion-slot backpressure: the owner must consume its terminal
record before another source can dispatch. Pending cancellation removes that
request immediately; active cancellation suppresses acceptance immediately but
does not claim the worker has terminated. Reset increments the epoch and fences
old results. Shutdown permanently rejects submissions and waits for owned work.

Discarded queue-owned payloads enter one bounded retirement slot. The same
worker retires them before another source dispatch. A holder establishes worker
ownership; after main-thread aliases are dropped, a semaphore permits the worker
to clear the holder's payload. The payload is not bound directly to a callable
that might survive until main-thread join. Start failure retains the slot for
retry and keeps shutdown incomplete. Repeated reset/cancel cannot overwrite it.
Once a result is consumed, its lifetime belongs to that consumer, not this queue.

## Initial evidence

All artifacts below are under `artifacts/citadel-runtime-integration/` and use
the process-owning watchdog. No headed test has been launched.

- `site-build-queue-smoke-01`: real threaded `Site.prepare` on a region with no
  candidate returns immutable `absent`, consumes once and drains shutdown.
  This is not a prepared-citadel result. Natural exit 0, empty stderr, owned zero.
- `site-build-queue-contract-01`: 132/132 explicitly synthetic, semaphore-gated
  queue/Thread checks. Submission/result alias isolation, duplicates, bounds,
  deterministic priority/fairness, reset/same-seed fencing, cancellation races,
  failure/retry and shutdown. Max observed poll 74 microseconds; 100 ms assertion
  is only a deadlock guard, not a gameplay frame-budget pass. Natural exit 0,
  clean logs and owned zero. It substitutes only source preparation/start failure;
  no generated geometry or gameplay acceptance is claimed.
- `site-queue-disposal-01`: synthetic worker replay of the actual hash-bound
  six-megabyte candidate through ordinary snapshot/freezing. Ownership checks
  passed, but completed reset/cancel cost 13.136/12.844 ms on the caller;
  stale-result joining/disposal recorded 19.129 ms in internal poll instrumentation.
  These are a live-readiness
  failure, not a performance pass. The failed timing boundary is retained and
  motivates worker-side retirement before live activation.

## Completed preservation and retirement evidence

- `site-build-queue-real-01`: real threaded `Site.prepare` for `atlas-1492`,
  region `(1,-3)`, passes 8/8 in 334.896 seconds. The complete authoritative
  result matches `actual-site-source-05` exactly after removing only root
  `preparationUsec` and six survey scheduling/timing fields (`slices`,
  `maxSliceUsec`, `maxColumnUsec`, `sliceOverruns`, `preparationUsec`, `workUsec`).
  Geometry, furniture/reservations, profile, manifests and source identity are
  not exempted. 16,165 lightweight polls, max 228 microseconds; natural exit 0,
  empty stderr, immutable result, consume-once and joined shutdown. Its complete
  result file SHA256 is
  `33d53eb2bf6f3a52f620f2f9f9f9f1442ae08800887a3ba3ef57ccd2e05e63a5`.
- `site-build-queue-contract-02`: final queue passes 206/206 synthetic checks,
  adding retirement priority/backpressure, repeated cancellation/reset,
  start-failure retention/retry, shutdown drain and worker final release.
  Max observed small-payload poll 86 microseconds. Natural exit 0, clean logs,
  owned zero. Reproduce with a fresh output path:
  `./tools/run-citadel-site-build-queue-contract.ps1 -OutputDirectory <fresh-path>`.
- `site-queue-disposal-04`: final queue replays that exact hash-bound real
  threaded payload through prepared-object conversion and deep freezing. All
  three complete payloads remain byte-exact; 5/5 checks pass. Every poll is
  timed externally, including dispatch/join. Reset/cancel are 16/26 microseconds;
  whole-owner polling maxima are 119/117/112 microseconds across reset, cancel
  and stale-join cases. Final release executes on worker thread IDs 58/62/66,
  not owner 1; measured destruction is 22.017/25.001/12.935 ms on those workers.
  All retirement drains complete, logs are clean, natural exit 0 and owned zero.

The critic approved chaining the real run to final retirement-only evidence
without rebuilding unchanged geometry. `site-queue-disposal-04/unchanged-preparation.json`
records exact bodies/hashes for `_run`, `_prepare_site`, `_freeze`,
`_canonical_request` and `_terminal`, and no changed preparation dependencies.
The pre-retirement queue is archived under the real run. This is explicit
evidence chaining, not a claim that the final retirement patch ran another full
recipe build. The replay is synthetic source-level evidence, not live gameplay.

The independent critic approved the final focused queue commit after inspecting
contract02, disposal04, the unchanged preparation evidence and process cleanup.
This approval excludes live dispatch, terrain admission, headed tests and goal
completion; deep source cancellation remains the next blocking prerequisite.

Disposal attempt 02 failed immediately on a test-only hashing API parse error;
natural exit 1 and owned zero are preserved. Attempt 03 passed ownership/parity
but did not externally time every poll. Attempt 04 closes that measurement gap.

## Required next work before live dispatch

The real build records a **232.534-second cancellation-checkpoint gap** inside
structural completion. The queue keeps polling responsive and rejects cancelled
results, but it cannot interrupt that work. Deep cooperative cancellation and
bounded shutdown latency remain mandatory; no live caller is enabled yet.

Next native terrain admission must cover the primary viewer, auxiliary viewers,
view-distance changes and generation halos before affected terrain is requested.
Do not swap the unlocked generator context while native tasks read it. Ordinary
structure/tree/door publication, unload/re-entry, saves, real menu/New Game
traversal, visual inspection and runtime performance remain unverified.
