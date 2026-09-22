# N4 unchanged NPC baseline regression — 2026-09-22

This records a pre-implementation stop gate under `MANIFESTO.md`. It is not
N4 acceptance, a native-backend defect attribution, or permission to alter
protected pathfinding code. The branch was at `38c7714d112dfe52b1781a7b7baf534176c2562d`
(`codex/world-streaming-maturity-migration`), with only this N4 contract
document modified during the baseline. Seed: `atlas-1492`.

## Commands and terminal evidence

- `node tools/npc/run-npc-contract-tests.mjs -TimeMode Both`: exit 0;
  `artifacts/npc/reports/contract-both.json` passed. This is contract evidence,
  not live gameplay acceptance.
- `node tools/npc/run-all-npc-tests.mjs -TimeMode Both`: exit 1 after
  1,168.932 seconds; `artifacts/npc/reports/all-npc-both.json` reports 17
  runners, four failures. The wrapper process terminated; a post-run
  read-only process inventory found no Godot/Node process whose command line
  referenced this worktree. A separate owned-job zero-member receipt was not
  located, so do not claim that stronger cleanup proof.

The four failing runners are:

| Runner | Report | Concrete result |
|---|---|---|
| `streaming_save` | `artifacts/npc/reports/streaming_save-both.json` | Two `npc_save_world_signature_unchanged` failures: baseline 423,894 bytes, latest 0 bytes. Read-only source review found the fixed ignored `artifacts/world-signature/latest/atlas-1492.json` missing; the NPC runner does not generate it, and the aggregate registry's separate world-signature runner writes elsewhere and runs later. Subsequent visible signature generation and focused rerun below prove this particular failure was fixture/order, not a save mismatch. |
| `real_tutorial_playthrough` | `artifacts/npc/reports/real_tutorial_playthrough-both.json` | Headed main-menu -> New Game; Mira did not reach strict home interior by the 42.824-second observation cutoff. Screenshot: `artifacts/npc/screenshots/real_tutorial_playthrough-both/mira_timeout_final_state.png`. |
| `real_tutorial_final_rescue` | `artifacts/npc/reports/real_tutorial_final_rescue-both.json` | Niko remained at the rescue site with return-home route `pending_budget`/`validation_step_budget_deferred`; failure `final_rescue_return_actor_stalled`. Mira was also pending validation budget in the same final snapshot. |
| `town_job_cycle_visual` | `artifacts/npc/reports/town_job_cycle_visual-both.json` | Wrapper exited 1 at about 300.5 seconds. The partial report contained seven precondition-only passes but `finished=false`; progress stopped at `observe_day_jobs_0660`. All 11 actors still had zero completed job runs at the last persisted day sample, with six active routes pending budget and none moving. This is a timeout, not a pass. |

## Mira timeline diagnosis, not a fix

The headed playthrough started Mira at cell `(267,-15)`; home was `(294,14)`,
door `(292,17)`, and strict interior XZ bounds were `(290,10)` through
`(296,16)`. She remained at the start while an incremental route search and
validation ran, then received a collision-backed route with 62 waypoints,
82.35 m routed length, proved door edges, and 244 capsule samples. At timeout
she was moving at cell `(288,11)`, outside the strict interior, with no
reported blocked motor contact or pending nav-data frames. The trace's
1,046 `pendingBudgetFrames` include active bounded search/validation work,
not 1,046 denied scheduler grants. Route planning took roughly 17.5 seconds;
the runner had estimated its window before the route existed using the
shorter direct distance. The observed failure is therefore real, but it does
not establish an unreachable home or defective door crossing. It also cannot
be solved by merely relabeling the runner green or extending its timeout:
route latency, generated-town detour, and ordinary-gameplay arrival still
need evidence-based analysis.

The earliest source change that caused these failures is not established.
There were no new native catalog, structure snapshot, or route-code edits
before this baseline. N4 implementation stays paused pending discussion of
the protected pathfinding scope and resolution/verification of these baseline
failures. Keep the original Gate 5 acceptance matrix open.

An older, pre-N0 G1 aggregate at
`artifacts/world-streaming-maturity/g1/baseline-20260914/all-npc-both.json`
is a useful but limited comparator. Its `real_tutorial_playthrough` and
`town_job_cycle_visual` children exited 0 after 127.178 and 216.624 seconds,
respectively, but the aggregate marked both failed because their reports
lacked the required `forbiddenCallSelfScan.status == passed` evidence. Their
exit status does **not** reproduce the current Mira interior miss or current
town-job 300-second timeout. Its `real_tutorial_final_rescue` child exited 1
after 166.985 seconds, with missing required captures and evidence-integrity
failure; the archived aggregate does not establish the same Niko
`validation_step_budget_deferred` cause. The pre-N0 state also contained a
large inherited Gate-5 working tree with routing/navigation edits later
preserved in `cfcc96f`. Thus neither matching runner names nor this aggregate
proves that the three current symptoms were introduced by, or predated, the
native N0-N4 changes. Same-source, same-seed headed comparison remains
necessary for causal attribution.

For the timed-out town job runner specifically,
`artifacts/node-tools/process-runs/godot-ItiQWw/watchdog.json` records
`timedOut=true`, forced job-object cleanup, `cleanupPassed=false`, and
`authoritativeZeroProven=true` with no final member PIDs. The owned engine
was terminated *because* the 300-second deadline expired; cleanup was not
the cause of the unfinished gameplay. Its roughly 6.7 observed physics
frames/s during day observation also made the requested 2,700-frame window
far longer than the wrapper deadline. Do not infer game-path acceptance from
the seven partial preconditions or count this forced cleanup as a clean
natural exit.

Capture review further bounds these results. The Mira midpoint capture shows
her outside a building, but the timeout capture does not frame her clearly;
the strict final cell comes from the live trace, not pixels alone. The Niko
returning capture shows him at the rescue site when the return phase starts;
the later no-movement conclusion comes from the route/status timeline, not
that single image. The town-job run produced only the town-setup capture, not
the required day-job/door/home captures. Its partial `day_0540` matrix has
11 actors, zero completed job runs, six pending routes (two each of
`planning_budget`, `candidate_validation_deferred`, and
`route_snapshot_changed`); the progress file reached
`observe_day_jobs_0660` at 292.068 seconds against a 2,700-frame day window.
Absent day-job screenshots cannot establish visual gameplay success or prove
that all actors are permanently stalled.

The final-rescue return timeline narrows Niko's case further. From samples
`final_rescue_return_018` through `_097` (time 132.38 to 141.08 seconds),
his request ID remains `niko:v2:3:27`, cell remains `(312,-20)`, and
`pendingBudgetFrames` rises from 55 to 577. It is not visibly cycling through
new request IDs in that interval. The final recent events show a planning
grant with two validation steps and zero actual search expansions, followed
by `validation_step_budget_deferred`. This proves repeated incremental
service while he does not move; the report does not expose enough substrate
cursor history to prove whether each grant advances useful preflight or
validation work. Do not label the pending counter itself as denied grants or
infer a permanent deadlock from this bounded observation.

## World-signature fixture diagnostic

`node tools/run-world-signature.mjs -Seed atlas-1492` was run without
`-UpdateBaseline`, targeting the exact missing latest path. It exited 1
without writing a signature. The owned receipt
`artifacts/node-tools/process-runs/godot-p2lZlw/watchdog.json` records a
run-local stop at about 59 seconds (`overallExitCode=126`, not a timeout),
forced cleanup, and authoritative zero owned processes. `stderr.log` contains
dummy-renderer RID/mesh-storage errors, beginning with `Initializing already
initialized RID`; no GDScript exception or signature-readiness milestone was
reported. `WorldSignatureRunner.gd` instantiates the real Main scene before
its first readiness milestone, so the exact offending visual/resource path
is not proved by this log. This reproduces a headless presentation/lifecycle
failure before signature serialization, not a deterministic-world mismatch.
The known historical dummy world-signature access violation remains a
separate unresolved possibility; this run did not establish that exact crash.

The headed diagnostic `node tools/run-world-signature.mjs -Seed atlas-1492
-Visible` then exited 0. It wrote the latest fixture and matched the tracked
`artifacts/baselines/world-signature/atlas-1492.json` byte-for-byte; owned
receipt: `artifacts/node-tools/process-runs/godot-FNfq5T/watchdog.json`.
With that fixture present, `node tools/npc/run-npc-streaming-save-tests.mjs
-TimeMode Both` exited 0. Its report
`artifacts/npc/reports/streaming_save-both.json` shows both day and night
`npc_save_world_signature_unchanged` assertions passing with 423,894 bytes
each. The original aggregate failure is explained by missing fixture and
runner ordering. This focused result does not clear the three remaining
headed NPC failures or establish full Gate 5 acceptance. The dummy-renderer
signature path still needs a separate source-level repair/verification before
it can serve as reliable headless evidence.
