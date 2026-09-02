# Cancellation during retained-paving preparation

## Scope

Continues from clean `d9cb0ce` on `codex/citadel-visuals-clean`. The compound
cancellation chunk is committed and critic-approved. This chunk removes another
source-worker cancellation gap; it does not enable ordinary runtime spawning.

`RetainedSurfaceBearingRecipe.prepare` and the composer's
`prepare_retained_paving` accept an optional final continuation. Both physical
proofs use the already verified private-copy cancellable validator when a
callback is supplied; omitted callbacks retain the old validator call.
Checks also cover adapter inputs, source parts, retired roots, target surfaces,
existing roots, candidate fragments, reservation cuts and finalization.

The validator releases its own temporary indexes on rejection/completion.
Separately, `Copy.clear_caches` strips derived per-part recipe proof fields from
the private copy; it is not itself the validator-index cleanup routine. The
partially prepared copy is discarded, not rolled back or reused. On rejection
the result is exactly
`{ready: false, reason: cancelled}` without a partial snapshot. The composer
propagates cancellation before interpreting ordinary failure, committing paving,
entering structural completion or invoking another callback. Geometry, order,
clearance, containment proofs, source identities and successful output remain
unchanged by design and require complete-output verification below. No changes
to NPC routing, save versions or tree recipes are included.

## Evidence in progress

All artifacts are under `artifacts/citadel-runtime-integration/`. Runs are
headless and process-owned; no headed approval or gameplay claim is made.

- `retained-cancellation-adapter-01`: existing synthetic composer adapter
  contract **17/17**, covering exact append/commit, idempotence, rejection
  without mutation and shared ordinary/portcullis door sweep reservations.
- `retained-cancellation-recipe-01`: existing synthetic recipe contract
  **21/21**, covering real retained volume, ordering, exact containment,
  overlap sharing, fragment/input limits and fail-closed rejection.

Commands, from this worktree (choose fresh directories for repeats):

```powershell
./tools/run-citadel-retained-paving-composer-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/retained-cancellation-adapter-01
./tools/run-retained-surface-bearing-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/retained-cancellation-recipe-01
```

Both existing contracts exited naturally with code 0, empty error logs and
watchdog-proven zero owned processes. Their reports are synthetic source
evidence, not proof of live collision or gate traversal.

`site-retained-cancel-01` passes **10/10** through the actual Queue -> Site ->
Source path, seed `atlas-1492`, region `(1,-3)`, scale 1.25. An observation-only
wrapper arms at `retained_initial_proof`; the main owner cancels during
`physical_resolve_support`. No substitute source, injected delay or direct
helper cancellation is used for this case. Cancellation call: 5 microseconds;
first rejection: 1.559 ms; actual Site return: 46.765 ms; joined result: 56.112 ms.
Externally timed polling peaks at 1.932 ms. Source and Site themselves return
cancelled with no blueprint/furniture, no subsequent callback and no structural
completion entry. The receipt is consumed once and retirement/shutdown drains.
Natural exit 0, empty errors, watchdog-proven zero owned processes.

Its launch metadata binds all dependencies. The exact watchdog command is in
`site-retained-cancel-01/watchdog.json`; the owned runner is `run.gd` in the same
directory and records request/return evidence in `cancel-request.json` and
`report.json`. Total runner work is 56.519 seconds, including the normal compound
and early composer stages. The declared watchdog is 120 seconds, based on the
previous roughly 65-second arrival at retained preparation; it does not extend
a gameplay timeout or wait for the later several-minute structural pipeline.

The actual stop proves this phase, not every future cancellation point or a
hard whole-build shutdown deadline.

## Exact boundary preservation

`retained-cancellation-baseline-01` passes 16/16 and archives Git `d9cb0ce`'s full
composer, bound to its full archived retained helper. A separate capture variant
returns the old adapter's prepared helper arguments; the original archived
composer executes the actual baseline proof. The complete result and input are
stored in `baseline.bin`, SHA256
`a2b3284924c3bf9c5d41ef964cc37b5ab09072080e8a7621b7154bdfdb6efee2`.
All unchanged transitive dependencies are hash-bound. This is historical actual
adapter input reconstructed from `actual-site-shop-02/result.bin` and
`paving-source-diagnosis-01/pre-urban.bin`, **not** a fresh complete Source build.
It has 4,442 source parts, 96 retired roots, 88 eligible target IDs and 469
protected volumes; three targets require retained support.

`retained-cancellation-adapter-omitted-01`, `adapter-empty-01`, `adapter-true-01`,
`helper-omitted-01`, `helper-empty-01`, and `helper-true-01` (all with the
`retained-cancellation-` prefix) pass 18/18, 18/18, 20/20, 18/18, 18/18 and 20/20
respectively. Complete typed results, not just signatures, are byte-identical
to the old baseline without exemptions. Blueprint/input values, original part
objects, RNG, archived baseline and bound source bytes remain unchanged.
The active-callback adapter maximum gap is 72.078 ms; helper maximum is 79.939 ms.
Both initial and final physical proofs are observed, and finalization is terminal.
These are measured source-worker gaps, not hard bounds or gameplay frame times.

`retained-cancellation-synthetic-03` passes 49/49 against the final test file
(extending the earlier 41-check run). It covers old/current support
output and failure equality, a no-change result, cancellation after a fragment
is staged, and cancellation at no-op finalization. Cancellation returns only
the canonical failure dictionary, does not mutate the original and never invokes
the callback again. Consecutive identical trace stages are coalesced with exact
counts and gap maxima; overflow fails instead of dropping evidence.

Eight historical-input cancellation controls pass **19/19 each**:
`adapter-entry-01`, `adapter-final-proof-2-01`, `adapter-finalize-01`,
`helper-entry-01`, `helper-initial-proof-2-01`, `helper-target-2-01`,
`helper-final-proof-2-01`, `helper-finalize-01` (all prefixed
`retained-cancellation-`). Both physical phases, repeated occurrences, partial
addition and final output staging are covered. Rejection-to-return ranges from
8 microseconds at adapter entry to 154.953 ms at adapter finalization; the latter
includes private payload cleanup. None returns a partial snapshot or invokes
another callback after rejection. This is distinct from the actual worker's
56.112 ms initial-proof cancellation and is not hidden behind that smaller value.

All final runs have passing complete reports, no engine/script errors, natural
exit 0 and watchdog-proven zero owned processes. Original baseline and per-run
script/dependency hashes are retained. The independent read-only critic approved
the focused two-file production change, contract/wrapper and scoped documentation
after checking parity, both proof stages, cancellation, source isolation and
owned cleanup. No live/headed, new full Source success run or hard shutdown bound
is approved. Existing synthetic regressions and exact helper/adapter parity do not
constitute live terrain or player traversal acceptance.

Repeatable examples (use fresh output paths):

```powershell
./tools/run-citadel-retained-paving-cancellation-contract.ps1 -Phase success -Target adapter -Mode true -AuthorizeCurrent -BaselineDirectory artifacts/citadel-runtime-integration/retained-cancellation-baseline-01 -OutputDirectory artifacts/citadel-runtime-integration/retained-cancellation-<fresh>
./tools/run-citadel-retained-paving-cancellation-contract.ps1 -Phase cancellation -Target helper -CancelStage physical_resolve_support -ArmStage retained_final_proof -CancelOccurrence 2 -AuthorizeCurrent -BaselineDirectory artifacts/citadel-runtime-integration/retained-cancellation-baseline-01 -OutputDirectory artifacts/citadel-runtime-integration/retained-cancellation-<fresh-cancel>
```

Each directory contains `launch.json`, complete `report.json`, compact
`summary.json`, logs and `watchdog.json`; the last records the exact Godot command
and owned-process cleanup. No screenshots are claimed for source-only work.

## Remaining integration

Perimeter dressing and tree-site selection still contain coarse source phases.
Native terrain admission, ordinary structure/tree/door publication, save and
streaming lifecycle, and critic-approved real-game visual/performance evidence
remain unfinished. Cancellation granularity is not construction speed, a hard
shutdown deadline, a gameplay-frame guarantee or normal-game spawning.
