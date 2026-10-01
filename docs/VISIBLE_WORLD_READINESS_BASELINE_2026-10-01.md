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

## Visual-readiness implementation findings

The configured terrain viewer range is 96 world meters, while terrain cells
are 1.35 meters. The terrain viewer's `view_distance` is already expressed in
world units; it must not be multiplied by cell scale. `MainCore` waits for
terrain view expansion and then foreground physical/navigation readiness, but
neither establishes complete visual coverage across that view.

The current chunk prop scanner consumes seeded RNG and constructs gameplay
bodies in the same operation. Generated trees begin their separate visual
queue only after the body exists, and `TreePublicationQueue` marks a tree
published only after its visual is committed. Structures explicitly report
physical-only readiness. No production publisher currently exposes a complete
expected-versus-represented visual manifest for terrain, structures,
trees/foliage, props, and wildlife. Consequently, the new readiness owner is
not wired into startup or traversal yet; doing so before the publishers can
describe their complete source state would either stall startup or falsely
report empty coverage.

The initial `VisibleWorldReadiness` contract was exercised with the owned
headless Godot runner and now passes 52 synthetic checks:

```text
node tools/run-visible-world-readiness-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/visible-world-readiness-eighth
```

Report: `artifacts/citadel-runtime-integration/visible-world-readiness-eighth/report.json`.
It covers request/source/view revisions, complete source enumeration, circular
view coverage, in-view candidates and tiers, installed owner receipts, stale
owner invalidation, and candidate accounting. It does not prove live visual
coverage or startup readiness. A separate headed normal-menu probe and the
production publisher integrations remain outstanding.
