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
| `streaming_save` | `artifacts/npc/reports/streaming_save-both.json` | Two `npc_save_world_signature_unchanged` failures: baseline 423,894 bytes, latest 0 bytes. Read-only source review found the fixed ignored `artifacts/world-signature/latest/atlas-1492.json` missing; the NPC runner does not generate it, and the aggregate registry's separate world-signature runner writes elsewhere and runs later. This is a missing-fixture/order failure, not proof of save mismatch. Actual signature parity remains untested. |
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
