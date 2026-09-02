# Fixed-axis courtyard packing repair

Independent critic approval: focused planner fix only, starting at `6ee9a64`
on `codex/citadel-visuals-clean`. No live-world or full-source acceptance.

The actual `atlas-1492` candidate in region `(1,-3)` selects recipe seed
`1298433643`, plains, scale 1.25. Its fixed-obstacle X displacement created
street and prior-residence overlaps despite requiring no courtyard-boundary
correction. The existing coupled repair was only entered for a boundary
correction. It now also runs after nonzero fixed-obstacle X/Z displacement.
The same geometry-derived candidates, 1024-candidate bound and exact rejection
checks remain. No named seed repair, authored placement, shrinking or omissions.

## Source evidence

Commands from this worktree (choose new RunName values for repeat execution):

```powershell
./artifacts/citadel-runtime-integration/packing-sidecar-baseline-01/run.ps1 -RunName packing-coupling-failseed-01 -Seed 1298433643
./artifacts/citadel-runtime-integration/packing-sidecar-baseline-01/run.ps1 -RunName packing-coupling-known237207443-01 -Seed 237207443
./artifacts/citadel-runtime-integration/packing-sidecar-baseline-01/run.ps1 -RunName packing-coupling-known208159-01 -Seed 208159
./artifacts/citadel-runtime-integration/packing-sidecar-baseline-01/run.ps1 -RunName packing-existing-synthetic-01 -Existing
./artifacts/citadel-runtime-integration/packing-sidecar-baseline-01/run-synthetic.ps1 -RunName packing-synthetic-subset-01 -Seed 237207443
```

Each directory under `artifacts/citadel-runtime-integration/` contains launch,
stdout/stderr and watchdog evidence; completed runs also contain `report.json`.
Independent pre-patch planner/builder copies come from `6ee9a64`; only global
class names and the copied builder's planner preload are redirected. The
sidecar EVIDENCE.md records verification of those transformations.

- Failing seed: 10/10, 79.610 seconds. Old planner reproduces the fixed-axis-only
  rejection. New planner preserves all 12 intents, evaluates 728/1024 candidates,
  and passes 96 street, 8244 structure and 66 prior-residence comparisons.
  Reversed fresh inputs produce identical complete plans; a corrupted placement
  is rejected.
- Reference 237207443: 10/10, 71.135 seconds. Complete old/new plans, source
  snapshots and recipes are byte-identical.
- 208159: preservation checks pass; 10/11 total, 16.239 seconds. BOTH old and new
  builders produce snapshot `b5485a5b48b7168e745fe8b1a39f9d2013c8fdcc1454da9670f9dbe63692a094`,
  not the unchanged historical expected
  `6caefa897a3cdd38492c899684535c8e1ed02153a8974d4e2c715102ffa307c0`.
  Recipe hash still matches. This isolates preservation across this patch; it
  does not resolve or waive that historical discrepancy.
- Unchanged full existing contract: timed out at 120 seconds, no completed
  report. Explicitly NOT a pass. Its three unchanged synthetic controls,
  separately invoked as a subset, pass 3/3.

All stderr logs empty. Each watchdog proves zero owned processes. Completed
runs exit naturally (208159 exits 1 for its recorded hash mismatch). The full
contract timeout exits 125 with forced cleanup and `cleanupPassed=false`;
zero remaining processes does not convert it to successful execution.

This commit does not include the subsequent shop-support or source-cancellation
changes. The seed runs predate the shop edit. No rendered visual, native terrain,
collision, trees, door, save, normal-game spawn or runtime budget claim is made.
