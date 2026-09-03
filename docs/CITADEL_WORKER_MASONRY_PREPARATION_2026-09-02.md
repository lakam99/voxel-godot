# Worker-prepared masonry descriptors

## Checkpoint boundary

Started from clean `584b9c8` on `codex/citadel-visuals-clean`. This change moves
existing CPU-only masonry descriptor work into `BuildingPublicationWorker`'s
post-diagnostic preparation. It does not change the citadel recipe, furniture,
history sampling, descriptor arithmetic, collision, shared tree pipeline, NPC
behavior, navigation, doors or save format. No headed test was launched.

The goal remains ordinary-world spawning. This is not activation, visual,
player-gate, save/lifecycle or runtime-performance acceptance.

## Implementation and ownership

- The same `MasonryDescriptorGeometry` cursor now runs on the preparation worker,
  with cancellation checks between 2,500-microsecond advances and during freezing.
  It includes ordinary and aperture-tagged masonry with the same visible
  wall/foundation selection as publication; cobble foundations remain on paving.
- Each prepared descriptor binds the original part object, complete typed part
  snapshot, canonical source ID and exact immutable history artifact. Geometry,
  entries and lookup maps are read-only. Source recipes are not frozen.
- The publisher validates before collision creation and before consuming the
  descriptor. Replaced/dropped artifacts and changed parts/history fail explicitly.
  Unknown eligible parts are missing preparation, not a fallback opportunity.
- Unsupported source graphs have explicit identity-bound omission records and
  use the existing incremental descriptor algorithm. Unexpected unsupported
  descriptor output fails instead of silently omitting an eligible part.
- Ordinary masonry borrows the frozen geometry. Aperture preparation borrows the
  same base geometry and retains separate mutable solids/clipping staging.
  Material evaluation, clipping, batch ordering and practical-light guards remain.
- Cancelled worker construction returns no partial artifact. Completed artifacts
  retain source/history ownership until the existing retirement worker releases
  them. Failed begin and clear detach both artifact and identity references.

`RecordBinding.encode` contains the previously approved zero-fill/native encoding
algorithm; the existing public `static_record_binding` delegates to it. No second
binding format was introduced.

## Final actual-source replay

```powershell
./tools/run-building-scene-publication-contract.ps1 -Phase actual -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-worker-masonry-actual-02
```

Seed `atlas-1492`, region `(1,-3)`, recipe seed `1298433643`, scale `1.25`.
Uses accepted `actual-site-source-05/result.bin`, SHA256
`7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`.
This replays publication from the accepted source; it is not a fresh procedural
site build or runtime prewarming.

Artifacts are under `artifacts/citadel-runtime-integration/` in the command's
directory: `launch.json` (16 source hashes), `report.json`, `progress.txt`,
`stdout.log`, `stderr.log`, `watchdog.json` and `render-baseline.json`.

Expected: identical recorded scene facts and complete publication, with all
masonry descriptors supplied by the worker and clean cancellation/retirement.
Actual: **68/68**, 1,450 prepared descriptors and 1,450 lookups. Ordinary masonry
descriptor-advance calls are zero; aperture descriptor advances are also unused.
The actual fixture still constructs 4,703 building parts, 210 furnishings, 3,179
blocking shapes, 20 site-scoped door IDs and four shared-queue trees. Door IDs are
not proof of gameplay registration or traversal.

The complete available scene record remains byte-identical to the preceding
checkpoints, including the synchronous-wall baseline. SHA256:
`1305dc7e22d27ed7c5616454bf52fe02e246f17940b772fde4a9f45935e03ba0`.
Headless MultiMesh readback contains placeholders; this is not GPU-instance or
screenshot acceptance. There are no screenshots for this source/service run.
Engine logs are clean, exit is naturally 0 and owned process membership is zero.

| Measurement | Previous incremental masonry | Worker-prepared final |
|---|---:|---:|
| Scene construction elapsed | 32.330 s | 22.484 s |
| Outer publication calls | 4,682 | 3,254 |
| Time measured inside advance | 12.239 s | 9.286 s |
| Time between advances | 20.082 s | 13.188 s |
| Masonry descriptor work on worker | none | 5.355 s |
| Whole background preparation, measured separately | not recorded separately | 24.803 s |

Scene construction and publication-call count improve by about **30%**. The
24.803 s background interval includes restoration, diagnostics, metadata, history
and masonry preparation; the 5.355 s masonry measurement is nested in it and must
not be added again. This work moved off-frame; it did not disappear. Neither
interval includes fresh multi-minute citadel source generation. They are not
normal-world startup measurements.

The earlier accepted synchronous-wall scene took **21.134 s**, so final
construction remains about **6.4% slower** than that baseline. The intermediate
`scene-publication-worker-masonry-actual-01` passed 68 checks in 23.538 s with
3,405 calls; final02 adds only the total background-preparation timer. Both have
the same scene-record hash. These are observations, not hard latency guarantees.

`advanceCpuUsec` uses elapsed ticks, not thread CPU accounting. Between-call time
includes result/status construction, caller work and frame waits, not pure sleep.
Nested timing sections overlap. Final remaining maxima:

- whole building finish: **22.610 ms**;
- roof part `castle_keep_civic_core_roof_left`: **17.851 ms**;
- static-flush commit: **13.809 ms**;
- aperture-preparation call: **9.269 ms**;
- building begin: **4.238 ms**.

Requested publication slices remain 2,500 microseconds; budgets above 4,000 are
rejected. Strict slice/atomic requirements still fail. No performance approval
or permission for a headed run follows from this improvement.

## Focused checks

Use fresh directories when repeating the commands; the listed paths hold the
executed evidence. All paths are beneath `artifacts/citadel-runtime-integration/`.
Each listed successful run has report, separate parse/run logs and owned watchdogs.

| Contract | Directory | Checks |
|---|---|---:|
| Worker descriptors, exact inputs, omissions, cancellation/retirement | `scene-publication-prepared-masonry-02` | 170 |
| Scene lifecycle, stale/missing preparation, pending cancellation | `scene-publication-worker-masonry-job-03` | 269 |
| Aperture parity and borrowed geometry | `scene-publication-worker-masonry-aperture-01` | 185 |
| Metadata compiler/binding regression | `scene-publication-worker-masonry-metadata-01` | 69 |
| Immutable history regression | `scene-publication-worker-masonry-history-01` | 108 |
| Paving/footing regression | `scene-publication-worker-masonry-paving-01` | 139 |
| Static batch/native submission regression | `scene-publication-worker-masonry-flush-01` | 131 |

```powershell
./tools/run-building-contract.ps1 -Contract BuildingPreparedMasonryContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-prepared-masonry-02 -ReportEnvironment BUILDING_PREPARED_MASONRY_OUTPUT -TimeoutSeconds 90
./tools/run-building-contract.ps1 -Contract BuildingScenePublicationJobContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-worker-masonry-job-03 -ReportEnvironment BUILDING_SCENE_PUBLICATION_JOB_OUTPUT -OutputIsDirectory
./tools/run-building-contract.ps1 -Contract MasonryAperturePublicationContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-worker-masonry-aperture-01 -ReportEnvironment VOXEL_MASONRY_PUBLICATION_REPORT
./tools/run-building-contract.ps1 -Contract BuildingPreparedMetadataContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-worker-masonry-metadata-01 -ReportEnvironment BUILDING_PREPARED_METADATA_OUTPUT -OutputIsDirectory -TimeoutSeconds 90
./tools/run-building-contract.ps1 -Contract BuildingPreparedHistoryContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-worker-masonry-history-01 -ReportEnvironment BUILDING_PREPARED_HISTORY_OUTPUT -TimeoutSeconds 90
./tools/run-building-contract.ps1 -Contract PavingFootingPublisherContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-worker-masonry-paving-01 -ReportEnvironment VOXEL_PAVING_FOOTING_PUBLISHER_REPORT
./tools/run-building-contract.ps1 -Contract BuildingStaticBatchFlushContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-worker-masonry-flush-01 -ReportEnvironment BUILDING_STATIC_FLUSH_REPORT
```

These are synthetic/contract tests, not gameplay. The descriptor contract covers
nine varied source records, including a tagged base descriptor, not a real sealed
aperture. The separate aperture contract and actual run supply that later evidence.

Failed attempts remain recorded: prepared-masonry-01 had a nested-class compile
error and was stopped by supervision; prepared-masonry-02 resolves it.
Worker-masonry-job-01/02 exited 1 with two retirement assertions and no engine
errors. Direct publisher/descriptor observations in the awaiting test retained
test-owned aliases. Observations moved to a synchronous helper returning only
weak references and scalar facts; job03 now verifies release of both publisher
and artifact. Production teardown was not changed to satisfy those tests.

## NPC preservation and next work

The unchanged owned-watchdog NPC scene was run headlessly with `--fixed-fps 60`,
45-second cap, seed `atlas-1492`, time mode `both`, empty case filter and suite
contract/motor/nav_world/route. `VOXEL_PLAYTEST=1`; both `VOXEL_TEST_SEED` and
`VOXEL_NPC_TEST_SEED` use that seed. Fresh per-suite report/progress/trace/screenshot
and userdata paths are in `scene-publication-worker-masonry-npc-<suite>-01/`.
The scene is `res://scenes/testing/npc/NpcAutonomyTest.tscn`, launched through
`tools/run-godot-scene-watchdog.ps1` using the bundled console executable.

Results are **84/84, 48/48, 84/84, 130/132**. All four stderr files are byte-exact
to `scene-publication-masonry-npc-<suite>-01`. The same exact-detour diagnostic
fails in day and night; previously acknowledged script/off-tree errors remain.
Route naturally exits 1, others 0; all owned processes exit. This preserves the
user-approved broken baseline, not an NPC health or live-routing acceptance claim.

Next: bound roof construction and final validation, then connect the prepared
scene job to ordinary service activation and verify player access, shared doors,
terrain continuity, streaming reconstruction, save/Continue, visuals and runtime
performance. Do not revive the removed citadel routing/resident subsystem.

The independent critic approved this focused worker-masonry preparation commit,
including parity, authority/ownership, regressions, preserved NPC baseline and
documentation. Strict budgets still fail. The active spawning goal remains
unfinished; no performance, whole-integration or headed approval is claimed.
