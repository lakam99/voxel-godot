# Citadel threshold footprint completion

Baseline: clean `codex/citadel-visuals-clean`, `55f2365`. Previous goal turn made
progress: committed structural row packing and isolated the next source defect.
No live Godot process was left behind. The goal remains successful ordinary-game
citadel spawning, not merely passing these source checks.

## Defect and owning change

The highest proven foundation under the failing threshold is a raised roadbed.
Its useful Z extent is about 0.1477 m shorter than the requested support footprint.
The old selection required only an overlapping contact patch, while the later
housed construction correctly required the entire support to fit inside the
seat. That mismatch rejected source preparation.

`ThresholdBearingFootprintFitter.fit_seat_footprint` intersects the proposed
support footprint with the selected seat's strict inset domain. It constructs
stored, representable XZ center/size values, preserving Y and already-fitting
axes exactly. Empty, undersized, nonfinite and unrepresentable domains reject;
rounding work is bounded. No existing geometry is moved or enlarged.

`ThresholdBearingSeatRecipe` calls it only when an eligible housed proposal
fails specifically on footprint containment, before any collision admission.
The highest proof-bound seat remains fixed. Existing housing dimensions,
embedment, joint validation, source/reservation admission and final structural
validation are unchanged. No routing, door-state, tree or save code is edited.

## Focused evidence

All artifacts below are under `artifacts/citadel-runtime-integration/`.

| Evidence | Checks | Meaning |
|---|---:|---|
| `threshold-fix-baseline-{housing,seat,footprint,courses}-01` | 189 / 147 / 236 / 558 | Unchanged source baseline, all pass. |
| `threshold-fix-{housing,seat,footprint,courses}-01` | 189 / 147 / 236 / 558 | Same existing contracts pass after the change. |
| `threshold-fix-bearing-01` | 498 | Existing bearing/admission contracts pass. |
| `threshold-housing-footprint-01` | 481 | Independent represented bounds, repeat/transform cases, malformed inputs and tiny actual-Part housing/root proof. |
| `threshold-fix-completion-02` | 169 | Existing completion plus fitted-highest-seat terminal proof, stale proof and unrelated obstruction/reservation rejection. |

These owned headless runs have clean parse/runtime logs, natural exit 0 and
authoritative owned-process zero. They are synthetic/source-level evidence,
not rendered or live gameplay acceptance.

Reproduce the new checks from this worktree, choosing fresh output directories:

```powershell
./tools/run-building-contract.ps1 -Contract ThresholdHousingFootprintContract.gd -OutputDirectory artifacts/citadel-runtime-integration/threshold-housing-footprint-02 -ReportEnvironment THRESHOLD_HOUSING_FOOTPRINT_OUTPUT -TimeoutSeconds 45
./tools/run-building-contract.ps1 -Contract CitadelThresholdCompletionIntegrationContract.gd -OutputDirectory artifacts/citadel-runtime-integration/threshold-fix-completion-03 -ReportEnvironment VOXEL_THRESHOLD_INTEGRATION_REPORT -TimeoutSeconds 30
```

Each directory retains `report.json`, parse/runtime logs and both watchdog
records. The commands above are reproduction commands, not additional runs.

`candidate-threshold-06` uses the locked historical unpacked source and its real
ordinary initial proof. The actual `_prepare_bound` path constructs and admits
the new bearing; a separate real terminal proof passes both the threshold and
bearing, with no previously passing part regressed. Total 16.622645 seconds;
terminal proof 7.685405 seconds. The source has 451 unrelated/unfinished physical
violations before and 450 afterward, not a whole-source pass.

The final admitted bearing is approximately 0.34 x 2.292786 x 1.143741 m,
with exact threshold contact, 0.0699998 m embedment into the same roadbed, and
unchanged existing source records. The ordinary obstacle fitter further narrows
it after the seat-footprint calculation; no obstacle is ignored.

Important limit: this historical snapshot does not contain the furnishing plan.
`furnitureObstaclesAvailable=false` and count 0 are recorded explicitly. Available
source parts and ordinary door/room reservations are checked; complete current
furnishing-policy acceptance requires the full production recipe replay.

## Complete current recipe replay

The independent critic provisionally passed all eight focused requirements:
highest-seat retention, pre-admission fitting, represented bounds, unchanged
vertical/joint rules, preservation/refusals, exact contact, unchanged admission
and terminal proof, and accurate evidence boundaries. Final focused commit
review awaits the complete replay result. One frozen headless replay was approved:

```powershell
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-05 -ExpectReady
```

This uses the existing 450-second source, 60-second independent-proof and
540-second outer budgets; no production or headed timeout is increased.

`candidate-recipe-05` passed on the frozen patch at baseline HEAD `55f2365`:

- World `atlas-30895044`, region `(0,-1)`, recipe seed `1747969299`, plains,
  scale `1.25`; unchanged production-derived input context.
- Public `CitadelRecipePreparation.prepare` ready in 233.255769 seconds.
- Separate full ordinary physical proof in 8.865670 seconds: all 4,562 parts
  checked, zero violations. The repaired threshold and bearing both pass;
  all 25 bearing coverage samples name the same proven final-turn roadbed.
- Actual source includes 142 furnishings, the interior program and the
  composer's furnishing-preservation result. Plan-owned access reservation
  count is zero; this is not a claim that ordinary rooms/doors lack reservations.
- Complete output retained before diagnostic physical validation in `source.bin`,
  SHA256 `4cffffaa1dc79a623e9b91c6851a25bec47898d301aa63170a8e996790abe46b`.
- Total 242.696 seconds; natural exit 0, no forced cleanup, clean engine logs,
  authoritative owned-process zero. Final audit proves all 748 measured source
  files unchanged, with no read errors.

Read `report.json`, `physical.json`, `timings.json`, `verification.json`,
`source-hash-audit.json`, parse/runtime logs and watchdogs together. The full
recipe uses its real furnishing policy, unlike historical isolation06. The
diagnostic does not run a separate furniture validator. No rendered appearance,
full Site terrain admission, native collision, scene publication, continuous
approach, door interaction or performance-budget acceptance follows from this
source-level pass. Cold preparation still takes several minutes on a worker.

Next: critic review and a separately approved bounded teleport-assisted headed
diagnostic using ordinary source preparation, never injecting this saved source.

Final read-only critic review: PASS for this seven-file focused commit after
Recipe05 and the report update. Separately approved one `candidate-teleport-02`
headed diagnostic on the reviewed unchanged runner/wrapper, with the existing
600-second cap and owned-stop guards. This is permission to collect evidence,
not advance acceptance of spawning, gameplay or performance.
