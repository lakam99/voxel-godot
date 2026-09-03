# Incremental roof publication

## Boundary and source

Started from clean `8ba8344` on `codex/citadel-visuals-clean`. Main owns publisher,
scene-job cancellation, integration controls and evidence. The worker owned only
`BuildingRoofPublication.gd` and its independent contract. No recipe, furniture,
tree, NPC, navigation, shared-door or save code changed. No headed run occurred.
The ordinary-spawning goal is not complete.

The existing roof arithmetic, course order, regular/weathered partition, custom
data, material inputs and eave/ridge caps now run through one resumable helper.
The synchronous entry drains that same helper, retaining its public batch and
custom-data hooks. Runtime packs individual tile/custom/collection/upload units
inside requested 2,500-microsecond slices; budgets above 4,000 are rejected.

The pending part keeps its index and initial collision until complete. Finish and
readiness remain pending. Part/source/history/parent guards reject stale work;
reentrant cancellation stops subsequent submissions. Arrays and native resources
remain owned until the existing scene retirement process releases them. Deferred
practical lighting runs once. Source validation itself has not been weakened or
split across mutable frames: four bounded timing categories were added only.

## Focused evidence

All directories below are under `artifacts/citadel-runtime-integration/` and are
fresh executed artifacts. Each focused wrapper records parse/run stdout, stderr,
watchdogs and a JSON report. All listed runs have clean engine logs, natural zero
exit and authoritative zero owned processes, with no forced cleanup.

| Contract | Directory | Checks |
|---|---|---:|
| Frozen old roof output, budgets, cancellation and guards | `scene-publication-roof-contract-01` | 253 |
| Existing scene lifecycle plus pending roof, cancellation and exact completion | `scene-publication-roof-job-01` | 328 |
| Masonry aperture regression | `scene-publication-roof-aperture-01` | 185 |
| Static batch regression | `scene-publication-roof-flush-01` | 131 |
| Paving/footing regression | `scene-publication-roof-paving-01` | 139 |

```powershell
./tools/run-building-contract.ps1 -Contract BuildingRoofPublicationContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-roof-contract-01 -ReportEnvironment BUILDING_ROOF_PUBLICATION_OUTPUT
./tools/run-building-contract.ps1 -Contract BuildingScenePublicationJobContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-roof-job-01 -ReportEnvironment BUILDING_SCENE_PUBLICATION_JOB_OUTPUT -OutputIsDirectory
./tools/run-building-contract.ps1 -Contract MasonryAperturePublicationContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-roof-aperture-01 -ReportEnvironment VOXEL_MASONRY_PUBLICATION_REPORT
./tools/run-building-contract.ps1 -Contract BuildingStaticBatchFlushContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-roof-flush-01 -ReportEnvironment BUILDING_STATIC_FLUSH_REPORT
./tools/run-building-contract.ps1 -Contract PavingFootingPublisherContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-roof-paving-01 -ReportEnvironment VOXEL_PAVING_FOOTING_PUBLISHER_REPORT
```

The roof oracle verifies its two frozen functions against Git commit
`8ba83443bb9e5483c097907df24c7c54db1daa56`, publisher blob
`4ace02cdd674f9b35324f5d2cd3b11a571eca0e2`. Six synthetic fixtures exercise
ordinary/monumental, left/right, narrow, thin and rotated source records in four
execution modes, including one-microsecond budgets. Native submission values,
not headless GPU readback, supply exact instance evidence. This does not prove
live roofs, player traversal or GPU fidelity. Helper SHA256:
`ac18c67ce88fd92ebbf86b877365042671e6a3ec9df77b3fb4daec359df332d6`.

## Accepted-source replay

```powershell
./tools/run-building-scene-publication-contract.ps1 -Phase actual -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-roof-actual-01
```

World seed `atlas-1492`, region `(1,-3)`, recipe seed `1298433643`, scale `1.25`.
Input remains `actual-site-source-05/result.bin`, SHA256
`7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`.
This is an accepted-source publication replay, not fresh source generation,
runtime prewarming or normal-world startup. The runner records 17 launch source
hashes and verifies they remain unchanged throughout the run.

Expected: complete scene construction with identical recorded output, all roofs
resumable, exact counts and clean retirement. Actual: **70/70**, all 68 visible
roof records pass setup/eave/ridge/finish exactly once. The same 4,703 building
parts, 210 furnishings, 3,179 blocking shapes, 20 door IDs and four production
queue trees are present. Door IDs do not prove gameplay registration/traversal.

Available scene record SHA256 remains exactly
`1305dc7e22d27ed7c5616454bf52fe02e246f17940b772fde4a9f45935e03ba0`.
Headless MultiMesh readback contains placeholders; no screenshot/GPU claim is
made. Inspect `launch.json`, `report.json`, `progress.txt`, `render-baseline.json`,
`stdout.log`, `stderr.log` and `watchdog.json` in the run directory. Engine logs
are clean, exit is naturally zero, and owned process membership is zero.

| Measurement | Prior worker-masonry replay | Roof replay |
|---|---:|---:|
| Background preparation | 24.803 s | 24.734 s |
| Scene construction | 22.484 s | 24.189 s |
| Outer publication calls | 3,254 | 3,504 |
| Elapsed inside advance | 9.286 s | 9.588 s |
| Elapsed between advances | 13.188 s | 14.592 s |
| Whole maximum atomic operation | 22.610 ms | 26.137 ms |

Largest roof unit is now **0.493 ms** (finish); tile work peaks at 0.321 ms,
custom data at 0.267 ms, collection at 0.245 ms. The old largest whole-roof part
operation was 17.851 ms. All-part submission now peaks at 7.177 ms, a masonry
facade rather than a roof. Roof units are not whole outer slices.

Construction is approximately **7.6% slower** than the prior checkpoint and
outer calls increase about 7.7%. Bounding a roof is not a throughput pass. No
claim is made that moved/sliced work disappeared. Background time is separate
from scene construction; both exclude fresh multi-minute source generation.
Inside-advance timing is wall elapsed, not CPU accounting; between-call time
includes caller/status work and frame waits, not pure sleep.

Strict budgets remain **failed**. Building finish peaks at 26.137 ms, static
flush commit at 14.755 ms, aperture preparation at 9.283 ms. New nested validation
maxima are: aperture source checks 7.972 ms, completed paving checks 5.850 ms,
history 0.008 ms, paving session 0.003 ms. These nested maxima overlap and should
not be summed into total runtime. Source validation remains intact; this evidence
identifies the remaining owner instead of authorizing an unsafe skipped check.

## NPC baseline and remaining work

The same owned-watchdog NPC scene was rerun headlessly, `--fixed-fps 60`, 45-second
cap, seed `atlas-1492`, time mode `both`, no case filter. Suite paths are
`scene-publication-roof-npc-{contract,motor,nav_world,route}-01/`, each with fresh
report/progress/trace/screenshot/userdata paths. Environment and scene command
match the worker-masonry checkpoint report; `VOXEL_PLAYTEST=1` and both seed
variables use `atlas-1492`. The exact command is retained in each watchdog.

Results remain **84/84, 48/48, 84/84, 130/132**. First three stderr files are
byte-exact to worker-masonry counterparts. Route fails the same exact-detour
diagnostic in day/night under the same 32,000-microsecond limit. It visits 4/5
cells versus prior 4/4; logs contain 247 error headers versus 244, with exactly
three additional occurrences of an existing off-tree stack and no new unique
error line. It is not a byte-exact route-log repeat. Natural exits are 0/0/0/1,
all owned memberships zero; no forced cleanup. The independent critic classified
this as the accepted broken-baseline timing variation, not a new regression.
This is not an NPC health or live-routing acceptance claim.

Next: finish the measured validation/publication work and connect ordinary service
activation, preserving terrain support, shared trees, physical access/readiness,
door registration/unload, reconstruction and durable save deltas. Do not keep
retuning the now-bounded roof. Shared per-door unregister requires explicit
protected-scope permission; the user has been asked, but no approval is presumed.
Headed Main/New Game approach/gate, visuals, save/Continue and runtime performance
remain unverified. The independent critic approved this focused commit after
checking ownership/cancellation, cursor/readiness, compatibility/parity, source
hashes, NPC classification and owned cleanup. It does not grant performance,
headed/GPU, ordinary-spawning or activation approval.
