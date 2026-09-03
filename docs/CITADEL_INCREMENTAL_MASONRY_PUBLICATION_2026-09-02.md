# Incremental masonry and prepared history

## Scope and status

Started from `76bb474` on `codex/citadel-visuals-clean`, preserving its existing
metadata checkpoint. This is a construction-publication checkpoint, not ordinary
world activation, visual acceptance, or completion of the citadel-spawning goal.
No protected NPC/navigation/door code or citadel recipe/furniture design changed.
No headed run was launched. Critic review remains required before one.

The former large wall operation now advances through the same deterministic
descriptor algorithm in both incremental and compatibility callers. Aperture
inventory, descriptor construction and descriptor-to-solid conversion also have
cursors. Multiple cheap units share each requested slice; cancellation retains
owned resources for the existing worker-retirement path. Native material/batch
ordering and compatibility override dispatch are preserved.

Callback failure cannot be overwritten by completion. Every masonry unit latches
publisher failure; part/source/parent/aperture authority is checked at entry and
before finish, and again after an emitted light's callback. No callback means no
redundant post-light check. Failed work does not advance the accepted part cursor.

The post-diagnostic preparation worker now optionally prepares immutable history
using the existing `SurfaceHistoryField.configure` algorithm. Its four containers
are isolated before recursive freezing. The publisher checks exact object,
source-ID and container identities instead of encoding the complete history for
each wall. Caller recipes remain mutable; unsupported graphs retain the mutable
compatibility path and exact comparisons. Clear replaces the history object;
failed begin and cancellation transfer retained ownership for retirement.

The incremental aperture entry borrows an exclusively owned runtime blueprint:
membership/order bind at begin and individual geometry binds when its request is
captured. This is not a begin-time geometry snapshot. The legacy `begin` adapter
still captures requests synchronously. Mutation before capture is unsupported
under runtime ownership; captured geometry/declarations remain validated.

## Actual-source evidence and timing

Command, from this project root:

```powershell
./tools/run-building-scene-publication-contract.ps1 -Phase actual -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-masonry-actual-03
```

Seed `atlas-1492`, region `(1,-3)`, recipe seed `1298433643`, scale `1.25`.
Input is the already accepted `actual-site-source-05/result.bin`, SHA256
`7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`.
No source recipe rebuild or known-seed runtime prewarming is claimed.

The run directory contains `launch.json` with 16 source hashes, `report.json`,
`progress.txt`, `stdout.log`, `stderr.log`, `watchdog.json` and
`render-baseline.json`. Expected: complete real publisher construction without
altering recorded scene facts, exact collision/cardinality and clean retirement.
Actual: **65/65**, 4,703 building parts, 210 furnishings, 3,179 blocking shapes,
20 site-scoped door IDs and four shared-queue trees. Door IDs are not gameplay
door registration or traversal evidence. Empty stderr, natural exit 0, no forced
cleanup and authoritative zero owned processes.

Available scene facts are byte-identical to `scene-publication-cache-actual-03`;
render-baseline SHA256:
`1305dc7e22d27ed7c5616454bf52fe02e246f17940b772fde4a9f45935e03ba0`.
Headless MultiMesh readback contains placeholders: this comparison cannot prove
GPU instance fidelity or replace inspected screenshots. No screenshots are claimed.

| Observation | Accepted synchronous baseline | Final incremental masonry |
|---|---:|---:|
| Scene elapsed | 21.134 s | 32.330 s |
| Largest ordinary part | 40.533 ms (wall) | 17.568 ms (roof) |
| Largest measured masonry descriptor advance | not separately measured | 2.673 ms |
| Main history configuration | 4.815 ms | 0.005 ms |
| Full-history boundary encodings | 287 | 0 |
| Prepared-history identity checks | none | 4,287; 9.387 ms total, 0.011 ms max |
| Static-flush commit maximum | 22.533 ms | 13.609 ms |

**The final run is about 53% slower overall than the accepted synchronous
baseline. This is not a performance pass.** Splitting the wall removes its large
atomic operation but adds scheduling/guard overhead. There were 4,682 outer
advance calls, 12.239 s measured inside advance and 20.082 s between calls.
The field `advanceCpuUsec` uses elapsed ticks, not thread CPU accounting;
`betweenAdvanceUsec` includes status/result construction, caller work and frame
waits, not pure sleep. These observations do not justify increasing slice budgets.

Final remaining maxima include whole building finish **22.304 ms**, roof
publication **17.568 ms**, static-flush commit **13.609 ms**, and aperture
preparation calls **8.229 ms**. Requested slices remain 2,500 microseconds and
reject budgets above 4,000. Measured overruns remain visible; strict slice/atomic
requirements fail. These nested timings overlap and must not be added together.

Intermediate runs are retained, not relabeled:

- `scene-publication-masonry-actual-01`: 62 checks, 38.675 s; lacked the final
  callback guard. Repeated history encodings cost 3.202 s over 3,194 calls.
- `scene-publication-masonry-actual-02`: 62 checks, 73.154 s after safety guards;
  authority validation consumed 14.089 s measured elapsed time and history
  encoding 3.513 s. These costs overlap. The immutable-history follow-up removes
  that repeated encoding while retaining the safety guards.

## Focused verification

All directories below are beneath `artifacts/citadel-runtime-integration/`.
Each has a report, run logs and an owned-watchdog summary. The general-wrapper
runs also retain separate parse logs/summaries; `masonry-descriptor-02` contains
its run watchdog only, not a separate parse watchdog. These are
synthetic/contract tests unless explicitly described as the actual-source run.

| Contract | Directory | Checks |
|---|---|---:|
| Historical descriptor parity, budgets, cancellation | `masonry-descriptor-02` | 327 |
| Immutable history, queries, eligibility, cancellation | `scene-publication-prepared-history-01` | 108 |
| Scene ownership, pending cursors, callback failure, history retirement | `scene-publication-masonry-job-06` | 221 |
| Aperture and incremental request preparation | `scene-publication-masonry-aperture-02` | 174 |
| Existing paving/footing publication | `scene-publication-masonry-paving-01` | 139 |
| Static flush and native setter submission parity | `scene-publication-masonry-flush-02` | 131 |
| Existing prepared metadata compiler | `scene-publication-masonry-metadata-01` | 69 |

Reproduce each with a fresh output directory:

```powershell
./tools/run-building-contract.ps1 -Contract MasonryDescriptorGeometryContract.gd -OutputDirectory artifacts/citadel-runtime-integration/masonry-descriptor-02 -ReportEnvironment MASONRY_DESCRIPTOR_OUTPUT -OutputIsDirectory -TimeoutSeconds 90
./tools/run-building-contract.ps1 -Contract BuildingPreparedHistoryContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-prepared-history-01 -ReportEnvironment BUILDING_PREPARED_HISTORY_OUTPUT -TimeoutSeconds 90
./tools/run-building-contract.ps1 -Contract BuildingScenePublicationJobContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-masonry-job-06 -ReportEnvironment BUILDING_SCENE_PUBLICATION_JOB_OUTPUT -OutputIsDirectory
./tools/run-building-contract.ps1 -Contract MasonryAperturePublicationContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-masonry-aperture-02 -ReportEnvironment VOXEL_MASONRY_PUBLICATION_REPORT
./tools/run-building-contract.ps1 -Contract PavingFootingPublisherContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-masonry-paving-01 -ReportEnvironment VOXEL_PAVING_FOOTING_PUBLISHER_REPORT
./tools/run-building-contract.ps1 -Contract BuildingStaticBatchFlushContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-masonry-flush-02 -ReportEnvironment BUILDING_STATIC_FLUSH_REPORT
./tools/run-building-contract.ps1 -Contract BuildingPreparedMetadataContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-masonry-metadata-01 -ReportEnvironment BUILDING_PREPARED_METADATA_OUTPUT -OutputIsDirectory -TimeoutSeconds 90
```

The descriptor oracle archives the old `76bb474` publisher's unchanged descriptor
functions and supporting scripts under `masonry-descriptor-reference-01/`.
Its publisher SHA is
`d0571ccfb9229a35cbf43769b9cc5a237eacafb3b76eaad432e94ccda224be2f`.
The actual raw civic tower produces 3,284 regular and 24 repair bricks, exactly
matching the old oracle at budgets 1/2,500/4,000. Source-wide final scene-fact
parity is separate evidence above; neither substitutes for visual acceptance.

## Failure supervision and regression boundary

The small-contract wrapper parses before execution and watches logs with shared
read access. A script error or watcher failure requests owned shutdown; watcher
errors are retained, not discarded. The actual-scene wrapper uses the same
shared-read/error-stop pattern. No process-name or unrelated-process kills.

`watchdog-contract-compile-01` and `watchdog-contract-runtime-01` are deliberately
negative controls: approximately 0.245/0.275 s error shutdown, forced cleanup,
exit 126 and owned-zero. They are not clean passes. `watchdog-contract-clean-01`
exits naturally. Initial `scene-publication-masonry-job-01` failed to parse and
reached its 30 s cap; it is retained as failed evidence. Job03's signature error
was stopped in approximately 0.338 s before execution. Job04 and subsequent
successful runs supersede those failed attempts, not erase them.

NPC regression command was the existing owned watchdog invoking
`res://scenes/testing/npc/NpcAutonomyTest.tscn --fixed-fps 60`, headless, 45 s cap.
Environment: `VOXEL_PLAYTEST=1`, `VOXEL_TEST_SEED=atlas-1492`,
`VOXEL_NPC_TEST_SEED=atlas-1492`, `VOXEL_NPC_TIME_MODE=both`, empty case filter,
and `VOXEL_NPC_TEST_SUITE` set successively to contract/motor/nav_world/route.
Report/progress/traces/screenshots/userdata paths were fresh per run in
`scene-publication-masonry-npc-{contract,motor,nav_world,route}-01/`.

Actual assertions: **84/84, 48/48, 84/84, 130/132**, respectively. Every stderr
file is byte-identical to its preceding `scene-publication-cache-npc-*-01`
counterpart. The same exact-detour diagnostic fails in day/night; existing
String/has_method and off-tree errors remain under the user's explicit baseline
exception. Route exits naturally 1; the others exit 0; all owned jobs empty.
This is preservation of the acknowledged broken baseline, not healthy NPC or
live pathfinding acceptance. No protected fix is included.

## Next work toward actual spawning

Move exact CPU-only descriptors into the existing preparation worker with
complete input bindings and cancellation/retirement, rather than paying their
construction and additional scheduling turns in gameplay frames. Keep the
shared descriptor algorithm and recipe output unchanged. Then bound the remaining
roof/final-validation work and connect the scene job to ordinary service
activation. Player access/readiness, shared-door cleanup, terrain continuity,
Main/New Game approach and gate traversal, unload/re-entry, saves, visuals and
runtime-performance acceptance remain open. NPC repairs remain deferred.

The independent critic approved this focused checkpoint and commit after
reviewing geometry/compatibility, ownership/failure handling, regressions, source
bindings, supervision and the documented timing tradeoff. No overall
integration, budget, live-spawn, or headed approval is asserted here.
