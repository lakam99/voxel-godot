# Cancellation during compound construction

## Scope

Continuation from clean `6994d2a` on `codex/citadel-visuals-clean`. This is a
source-worker shutdown prerequisite, not ordinary-world spawning acceptance.
Existing towns, protected NPC routing, tree publication, visuals, furniture,
terrain admission, saves and live publication are not changed by this patch.

`CastleCompoundBlueprintBuilder.build_with_diagnostics` and
`build_from_compound` accept an optional final continuation. Omitted and empty
callbacks retain the same successful construction path. Checks surround source
sampling, major geometry phases and each residence; district placement passes
the continuation into `CastleCourtyardDistrictPlacementPlanner.plan` and
`validate_plan`. Candidate search and exact structure/prior-residence comparisons
can stop between units without changing ordering, geometry math or telemetry.

A rejected callback returns immediately. Planner cancellation is distinct from
infeasible geometry and contains no partial placements. The builder returns null
with only `failureReason: cancelled`; its caller maps this to cancelled before
interpreting failure or starting the urban composer. Callbacks are not stored in
recipes, diagnostics, snapshots, source identities or saves. These APIs operate
on private, worker-owned construction; they are not resumable gameplay slices.
The courtyard call keeps a local terminal cancellation latch; a caller reusing
old output diagnostics cannot accidentally cancel a new invocation.

## Measured hotspot and actual cancellation

Artifacts below are under `artifacts/citadel-runtime-integration/`. All launches
are headless, with fresh paths and the existing process-owning watchdog. Its
`watchdog.json` records the exact command, deadline, exit and owned-job cleanup.
Input is the real `atlas-1492`, region `(1,-3)` candidate at scale 1.25, from
`actual-site-source-05/result.bin`, SHA256
`7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`.

- `compound-phase-profile-01`: coarse checkpoints isolate courtyard placement
  at 37.651 seconds of a 38.445-second compound build. Output prepared, sources
  stable, natural exit 0, empty errors, zero owned members.
- `compound-phase-profile-02` (before the reused-diagnostics follow-up): with inner checkpoints the full compound still
  prepares. Largest observed callback gap is 200.184 ms (street construction),
  followed by 154.192 ms (terraces); the placement-domain gap is 111.414 ms.
  Total is 42.743 seconds with diagnostic callback recording/logging. This is
  not a construction-speed benchmark or proof of a hard latency ceiling.
- `site-compound-cancel-02` (final production code): real Queue -> Site -> Source, observation-only
  wrapper, cancellation requested during an exact structure check inside
  coupled courtyard candidate search. **10/10 checks**. Cancellation call:
  4 microseconds; first rejection: 74 microseconds after request; actual Site
  return: 13.937 ms; joined source/result: 33.357 ms. External whole-poll maximum:
  9.240 ms (including retirement thread startup), not a passing runtime frame
  ceiling. Source and Site themselves return cancelled, with no
  blueprint or furniture, no composer entry and no callback after rejection.
  Receipt consumed once; shutdown drains; natural exit 0 and zero owned members.
  Earlier `site-compound-cancel-01` also passed 10/10 before the compatibility
  follow-up (13.791 ms result, 104 microseconds poll maximum); it is retained as
  interim evidence, not substituted for the final run's larger observed maxima.

The profiler scripts and launch metadata are preserved in their artifact
directories. To repeat either profile, copy the runner to a fresh directory and
change its output prefix; never overwrite the original evidence. Launch via:

```powershell
./tools/run-godot-scene-watchdog.ps1 -ProjectPath $PWD `
  -GodotExe 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe' `
  -Headless -Scene '--script' -SceneArguments @('res://artifacts/citadel-runtime-integration/<fresh>/run.gd') `
  -TimeoutSeconds 90 -StdoutPath 'artifacts/citadel-runtime-integration/<fresh>/stdout.log' `
  -StderrPath 'artifacts/citadel-runtime-integration/<fresh>/stderr.log' `
  -SummaryPath 'artifacts/citadel-runtime-integration/<fresh>/watchdog.json' `
  -StopRequestPath 'artifacts/citadel-runtime-integration/<fresh>/stop-request.txt'
```

## Preservation and review

Final source contracts pass. The independent read-only critic approved this
focused compound-cancellation commit after checking exact-output preservation,
diagnostics reuse, all cancellation/failure controls, dependency bindings and
owned-process cleanup. This approval does not include live spawning, a hard
shutdown deadline, a new full Site success run or headed testing.
Baseline `compound-cancellation-baseline-01` captures all 5,204 compound
parts and diagnostics before urban completion, using Git `6994d2a` and unchanged
dependencies. This is distinct from the completed Site's 4,703-part output.

- `compound-cancellation-final-omitted-02`, `final-empty-02`, and
  `final-true-02` (each with the `compound-cancellation-` prefix): 18/18,
  18/18 and 20/20 checks pass respectively.
  Complete typed blueprint snapshots and complete diagnostics are byte-exact
  against the old baseline with **no exemptions**. Caller context, global RNG,
  baseline bytes and bound current dependencies are unchanged. Always-true
  callback maximum gap is **222.905 ms** on final code. Build durations are
  39.880 / 56.480 / 50.687 seconds respectively; overlapping execution and
  callback tracing make these unsuitable as a comparative speed benchmark.
- `compound-cancellation-reuse-reference-02` and `compound-cancellation-reuse-02`:
  separate old/current builds with the same reused cancellation diagnostics.
  The current runner first really cancels construction, then reuses its output
  diagnostics for another build. Entire blueprint and diagnostics are exact
  against the archived old-builder/old-planner reference, including preservation
  of old diagnostic fields rather than resetting them. Reference 21/21 and
  current 24/24 checks pass.
- Ten builder cancellation controls pass **18/18 each**: `entry-02`,
  `intermediate-02`, `candidate-2-02`, `structure-proof-2-02`, `prior-proof-2-02`,
  `validation-02`, `validate-record-2-02`, `record-2-02`, `room-2-02`, `final-02`
  (all prefixed `compound-cancellation-`). Each proves the requested occurrence
  was reached, no later callbacks, explicit cancellation-only diagnostics and
  no returned blueprint. Recorded rejection-to-return times range from
  24 microseconds to 15.394 ms, excluding the separate actual-thread test.
- `compound-cancellation-source-entry-02`: **18/18**, real Source entry mapping
  returns cancelled without partial blueprint, furniture or interior program.
  Its first timing interval includes loading the Source script and is not a
  compound-construction atomic measurement.
- `compound-cancellation-ordinary-failure-02`: **18/18**, malformed compound
  remains an ordinary build failure, byte-exact against the old implementation.
  Exactly two expected error messages (one old, one current) are inventoried;
  no unexpected errors, natural exit 0 and clean owned-process shutdown.
- `compound-cancellation-planner-03`: **34/34**, explicitly synthetic pair made
  from actual residence recipes. Direct public plan/validation output is exact
  for omitted/empty/true callbacks, default options and a genuinely infeasible
  input. Inputs and source blueprints remain unchanged. `planner-02` is retained
  as a failed test: it incorrectly required a nonexistent top-level `passed`
  field even on the old planner. The correction asserts `status: ready` and
  `validation.passed`, retaining complete old/new comparisons. No production
  change was made for that fixture error and no legacy district-suite pass is
  claimed.

All final successful runs above have complete passing reports, clean error
inventories (apart from the two explicitly expected failure-control messages),
natural exit 0 and watchdog-proven zero owned processes. Interim runs remain
separate. Changing test logging or adding a case does not substitute a later
runner for the exact per-run archived script and hashes.

The old baseline's SHA256 is
`12650d3e3cd9772026aaa17237511ea63535a75442aed64f5536bce3463f7ae1`.
Only the global class name is removed from the archived builder; later reference
controls additionally bind its planner preload to the archived Git planner.
All other transitive source dependencies remain bound to their baseline bytes.
The wrapper archives exact Git dependency bytes and the runner used per launch.

Reusable wrapper examples (choose fresh output paths; the old baseline is never
overwritten):

```powershell
./tools/run-citadel-compound-cancellation-contract.ps1 -Phase success -Mode true -AuthorizeCurrent `
  -BaselineDirectory artifacts/citadel-runtime-integration/compound-cancellation-baseline-01 `
  -OutputDirectory artifacts/citadel-runtime-integration/compound-cancellation-<fresh>
./tools/run-citadel-compound-cancellation-contract.ps1 -Phase cancellation -AuthorizeCurrent `
  -CancelStage compound_placement_candidate -CancelOccurrence 2 `
  -BaselineDirectory artifacts/citadel-runtime-integration/compound-cancellation-baseline-01 `
  -OutputDirectory artifacts/citadel-runtime-integration/compound-cancellation-<fresh-cancel>
```

`launch.json`, `report.json`, `error-inventory.json`, and `watchdog.json` bind
commands, inputs, full checks, unexpected-error inventory and owned cleanup.
These are source contracts, not live gameplay evidence.

## Limits and remaining work

No fresh full Site success run is claimed for this compound-only change. Exact
whole-compound handoff comparison combines with the previously
verified unchanged downstream pipeline; it does not become live acceptance.
No screenshots are claimed or appropriate for these source-only tests.

The measured improvement is cancellation granularity, not faster generation.
Single comparisons and later geometry phases remain synchronous off-thread;
222.905 ms is an observation, not a universal ceiling. Compact-courtyard internals
do not gain the district planner's checkpoints. Other source stages, including
retained paving and perimeter dressing, still require cancellation work.
Native terrain admission, ordinary publication, saves/lifecycle, real player
approach and critic-approved headed visual/performance acceptance remain open.
The active goal is not complete.
