# Visible-World Readiness Baseline

**Recorded:** 2026-10-01  
**Branch / revision:** `master` / `3d957f2465aa66c773ff47c10ddeed6fd49cbcdc`  
**Worktree:** `voxel-biome-world-godot-master`  
**Related plan:** `C:/Users/arkam/Documents/voxel-godot-docs/migrations/world-streaming/visible-world-readiness-plan.md`

## Existing NPC gameplay failure

Before visible-world implementation, the required unchanged-baseline NPC run
was started with:

```text
node tools/npc/run-all-npc-tests.mjs -TimeMode Both
```

The aggregate reached the live final-rescue return scenario on seed
`atlas-1492` and recorded `final_rescue_return_actor_stalled` for Niko. The
snapshot records `routeStatus=pending`,
`routeReason=validation_step_budget_deferred`, `routeForceReplan=true`, and no
route cells. The route authority was still in `pending_budget` after 673
pending-budget frames; this is a gameplay failure in the unchanged baseline,
not a failure introduced by visible-world changes.

Evidence:

- Test report: `artifacts/npc/reports/real_tutorial_final_rescue-both.json`
- Owned-process cleanup record:
  `artifacts/node-tools/process-runs/godot-2FkbjN/watchdog.json`
- The child Godot command used `--time-mode Both --final-rescue --god-mode
  --seed atlas-1492`.

The aggregate was stopped when this first live regression was observed, so the
full `run-all-npc-tests` suite did not complete. The failing child exited with
code 1; its watchdog reports successful cleanup and authoritative zero job
members. Earlier in the same baseline session, the startup-readiness contract
passed 75 checks, the tree-publication contract passed, and the headed go-home
playtest completed its door/interior sequence. Those results do not negate the
final-rescue failure or constitute visible-world acceptance.

This issue is recorded as a pre-existing gameplay limitation for the
visible-world work. Per the user's direction, continue the visible-world plan
without changing protected NPC pathfinding code; report any later NPC result
against this baseline and do not claim this task repaired the failure.
