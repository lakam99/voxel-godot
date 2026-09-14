# World streaming maturity Gate 1 runtime lifecycle

Date: 2026-09-14
Gate status: **LIFECYCLE COMPLETE; PERFORMANCE ACCEPTANCE PENDING**
Next gate: **G2 MAY START; G2 HAS NOT STARTED**

## Outcome

Gate 1 completed the correctness cutover for local player motion, stable demand
identity, incremental Citadel scene publication, actor-safe transaction
activation, navigation acknowledgement telemetry and one shared gameplay
publication budget. The fixed-seed headed scenario now reaches first-useful
scene readiness, moves the player through ordinary input, publishes real
collision/furniture/door content, finishes its navigation audit and shuts down
cleanly.

Performance is not accepted. The final fixed-seed Citadel approach still has
severe presentation stalls, now attributed to the pure
`CitadelPublicationService` demand-refresh/view-window ranking path. The normal
five-minute sprint meets its presentation-cadence target but records a separate
autosave snapshot budget failure. These named residual computations qualify for
the migration plan's G1 exit exception: G2 profiling may start while performance
acceptance remains PENDING. No native candidate was promoted.

## Commits and preserved ancestry

- Gate 0 snapshot: `94d823cdbad8425553c0a76b3f4e4fc5f2d662a3`
- Gate 0 ledger: `1e6ef8887953d338c623d6a11074295777c4057e`
- G1D navigation slice telemetry: `8306d3b83e66fdbfb1136ffa5a0d1417eecd5971`
- G1 lifecycle cutover: `26383424afa699d06d8e3780efe951394ff1532d`
- Branch: `codex/world-streaming-maturity-migration`
- Gate 0 ledger to implementation HEAD: 22 files changed, 934 insertions and
  166 deletions. Protected NPC route, motor, door-execution and traffic code was
  not changed.

## Implemented sub-checkpoints

### G1A — movement isolation and attribution

- Player motion now asks only the authoritative `VoxelTerrainRuntime` for a
  bounded swept local collision-publication proof. It performs no Citadel
  structure, navigation, site-profile or height/surface scan in the hot path.
- Motion receipts are bound to seed, terrain instance, collision-owner
  generation, chunk key and edit revision. A durable edit invalidates the
  affected 3×3 receipt neighbourhood immediately.
- Long sweeps retain an explicit progression wait instead of skipping cells.
- The complete player physics callback, motion preflight, sample count and
  physics-ticks-per-presented-frame are measured.
- The normal-runtime collision observation was updated after the cutover: it
  pairs the new local publication receipt with the player's actual upward
  `VoxelTerrain` slide contact. It does not reintroduce a diagnostic ray into
  production motion.

### G1B — demand identity, locality and view priority

- `WorldStreamingCoordinator` has separate membership/source and view
  revisions. Camera-only changes update retained view intent without rebuilding
  stable source membership or handles.
- `CitadelPublicationService` accepts view intent independently of durable
  source demand. View changes do not invalidate the source transaction.
- Production whole-source fallback was removed. Oversized/ineligible packet
  plans remain explicit retryable failures or retained demands.
- The remaining costly all-group view ranking is recorded below as a G2 pure
  computation target; it is not accepted as runtime-budget compliant.

### G1C — installation, occupancy and retained completion

- Physical packet offer and activation are separate. A fresh bounded physics
  guard runs immediately before activation and covers players, NPCs, hostiles
  and wildlife with true 3D separation.
- Occupied transactions remain queued. Independent transactions within the
  same Citadel can progress, and packet roots remain pinned until their exact
  acknowledgement or retirement.
- Scene readiness is now distinct from full-site/background completion. The
  first-useful closure is deterministic generated-source policy: two complete
  urban home furnishing sets, a publishable door and one real stair/landing
  collision group plus dependencies. It contains no seed, region, named-NPC or
  authored building exception.
- Background rolling windows continue after first-useful readiness. They do not
  make the player wait for all 4,098 groups.
- Compact scene diagnostics now report physical groups complete/total, retained
  group requests and active foreground group count correctly.

### G1D — navigation slices and acknowledgement

- Capture, upload, installation and acknowledgement expose distinct per-slice
  timings instead of conflating accumulated job time with one frame.
- Real frozen nonempty packet navigation reached exact revision-matched engine
  installation and acknowledgement; cancellation/shutdown drained cleanly.

### G1E — shared gameplay budget and backpressure

- Ordinary gameplay establishes one 6 ms publication frame token/deadline.
  Citadel publication can claim the remaining budget once, is capped at 4 ms,
  and cannot open a second private allowance from its terrain callback.
- Explicit initial/replacement loading retains its separately owned bounded
  slice.
- Gauges/counters expose granted budget, aggregate elapsed work, maximum atom
  and overruns. Fixed-capacity per-section rings provide p50/p95/p99 without
  confusing section samples with global frame samples.
- Lifecycle correctness is complete, but the reports still show controllable
  pure orchestration overruns. They remain a release blocker and the first G2
  profiling target.

## Decisive headed evidence

Exact command:

```powershell
node tools/run-citadel-candidate-teleport-playtest.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-g1-final-20260914-06 -Seed atlas-3376622889 -CandidateRegion '-2,-2' -SpawnCell '-3334,-2666' -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600
```

Report:
`artifacts/citadel-runtime-integration/candidate-teleport-g1-final-20260914-06/report.json`

- Result: PASS, `scene_ready`, zero setup teleports, exact seed and region,
  clean owned-process shutdown and unchanged frozen sources during the run.
- The player used ordinary W/Shift viewport input. Close approach completed in
  30.570 s and stopped 7.077 m from published visual bounds. No modal loading
  appeared during either approach phase.
- Scene audit: two complete generated urban-home interiors, one registered
  door, seven of seven acknowledged source colliders exact, and three live
  player-capsule stair/landing clearance observations.
- Navigation publication and inspection captures passed. Inspected captures:
  `ready.png`, `close.png`,
  `castle_gatehouse_wall_stair_base_landing.png` and
  `home_interior_urban_civic_house_east_door_side.png` in the report directory.
- Visual limitation: first-useful readiness is deliberately sparse. It proves
  the acknowledged packet, not a fully rendered city, continuous tutorial-to-
  Citadel travel, door traversal, interior player traversal or NPC behaviour.

### Before/after presentation cadence

| Interval | p50 | p95 | p99 | max | Result |
|---|---:|---:|---:|---:|---|
| Gate 0 fixed-seed approach | 358.3 ms | 508.1 ms | 550.6 ms | 579.216 ms | rejected |
| Early G1A headed approach | 355.3 ms | 471.3 ms | 521.6 ms | 527.255 ms | rejected; motion isolation alone insufficient |
| Final G1 ordinary input approach | 16.5 ms | 497.2 ms | 531.3 ms | 583.9 ms | lifecycle PASS; performance rejected |
| Final G1 overall headed observation | 16.7 ms | 17.7 ms | 45.4 ms | 746.879 ms | includes startup, publication and diagnostic phase boundaries |

The bimodal final approach is not a movement proof regression: the actor moves
normally between large stalls. `demand_refresh` is the dominant service unit,
with 3,940 calls, 32.459 s accumulated CPU and a 565.742 ms maximum call;
service `maxAdvanceUsec` is 566.022 ms and `sceneMaxStepUsec` is 556.732 ms.
Worker packet preparation and scene atom timings remain separately reported.
The next action is to profile and replace the all-group rank/closure scan with
an incremental immutable spatial/view index in G2, not to alter movement or
promote a native backend prematurely.

## Ordinary five-minute sprint

Exact command:

```powershell
node tools/run-normal-runtime-performance-pass.mjs -Resolution 1920x1080 -DurationSeconds 300 -TimeoutSeconds 600 -ReportPath artifacts/world-streaming-maturity/g1/normal-sprint-01/report.json -ProgressPath artifacts/world-streaming-maturity/g1/normal-sprint-01/progress.txt
```

Seed `atlas-12495529`; normal `MainMenu.tscn` visible New Game path; no
`VOXEL_PLAYTEST`, fast boot, fixed FPS, seed override or save-path override.

- 17,731 measured frames, 2,866.575 m travelled, 27 traversal chunks and 34
  direction changes.
- Main callback distribution: p50 4.694 ms, p95 9.083 ms, p99 11.875 ms,
  max 26.705 ms. This runner does not provide OS presentation cadence; the
  fixed-seed headed report above provides frame-post-draw cadence.
- No terrain collision hold occurred. The original full run recorded zero
  collision samples because it expected the retired ray-sample schema.
- A 15 s ordinary-startup correction run at
  `artifacts/world-streaming-maturity/g1/normal-sprint-collision-schema-02/report.json`
  recorded 311 live VoxelTerrain slide-contact samples, 133.85 m travel and
  five chunks. Its only failure was the intentionally too-short direction-count
  criterion (one versus three); it is schema verification, not replacement
  five-minute performance evidence.
- Remaining real failure: autosave snapshot maximum 6.164 ms exceeds the older
  2 ms main-thread criterion; JSON read/parse was 0.747 ms and worker
  stringify/write was 5.274 ms. The main `autosave_snapshot` owner remains a
  G2/G4 performance item.
- Recorded orchestration maxima include 19.282 ms for
  `gameplay_publication_orchestration`, 18.904 ms for
  `streaming_region_demand`, and 10.953 ms for
  `streaming_coordinator_advance`. These are not summed and are not relabelled
  as presentation frames. They confirm performance acceptance is still pending.

## Focused verification

| Scope | Result | Evidence |
|---|---|---|
| Project compile smoke | PASS | `artifacts/node-tools/run-project-compile-smoke.json` plus post-commit owned watchdog `artifacts/node-tools/process-runs/godot-gcvkfg/watchdog.json` |
| G1A native motion admission | 66 checks PASS | `artifacts/citadel-runtime-integration/native-admission-g1a-20260914-02/report.json` |
| Real voxel collision publication | PASS | `artifacts/world-streaming-maturity/g1/g1a-collision-publication-01.json` |
| G1B retained demand/manifest | 72 checks PASS | `artifacts/world-streaming-maturity/g1/g1b-retention-manifest-01.json` |
| World streaming consumer | 102 checks PASS | `artifacts/citadel-runtime-integration/world-streaming-consumer-g1-final-20260914-01/report.json` |
| Publication service/first-useful policy | 149 checks PASS | `artifacts/citadel-runtime-integration/publication-service-g1-structural-window-20260914-03/report.json` |
| Packet job ordering/occupied rotation | 545 checks, zero failures | `artifacts/citadel-runtime-integration/scene-job-packet-order-g1c-20260914-02/report.json` |
| Exact 3D construction-member guard | 109 checks PASS | `artifacts/world-streaming-maturity/g1/g1c-construction-members-02.json` |
| Nonempty packet navigation ack | 12 checks PASS; 18 groups, 278 installed surfaces | `artifacts/citadel-runtime-integration/actual-packet-nonempty-navigation-ack-g1d-20260914-02/report.json` |
| Terrain/navigation mapping | 10 checks PASS | `artifacts/world-streaming-maturity/g1/voxel-terrain-navigation-publication-mapping-g1d-20260914-01.json` |
| Navigation cancellation/shutdown | 262 results, zero failures | `artifacts/test-runners/navigation-shutdown-lifecycle-report.json` |
| NPC contract, Both modes | 86 results, 258 assertions, zero failures | `artifacts/world-streaming-maturity/g1/npc-contract-both-final.json` |

The final NPC command was:

```powershell
node tools/npc/run-npc-contract-tests.mjs -TimeMode Both -ReportPath artifacts/world-streaming-maturity/g1/npc-contract-both-final.json
```

The Gate 0 full NPC aggregate was also preserved at
`artifacts/world-streaming-maturity/g1/baseline-20260914/all-npc-both.json`.
It reported five registry failures: four otherwise-passing headed reports lacked
the aggregate validator's `forbiddenCallSelfScan` field, and the existing final
rescue scenario ended in `search_budget_deferred`. These are classified baseline
evidence, not claimed as Gate 1 live NPC acceptance and not hidden by the green
contract matrix.

## Failed attempts retained

- `candidate-teleport-g1-final-20260914-01`: timed out after about 683 s because
  scene readiness incorrectly waited for the whole 3,676-group source.
- `...-03`: first safety window became ready without useful content.
- `...-04`: collision was exact but only one door and no two complete homes were
  present.
- `...-05`: movement, homes, door and scene audit passed; the first-useful
  closure omitted a stair/landing sample, so structural clearance was
  unevaluated. This directly motivated the semantic structural anchor.
- Publication service `...structural-window-01` and `-02` preserve the initial
  fixture assertion mismatch; `-03` is the corrected passing control.
- `normal-sprint-collision-schema-01` failed at parse time before gameplay;
  `-02` is the clean corrected observation.

## Source and binary identity

All hashes are SHA-256 at implementation commit `26383424afa699d06d8e3780efe951394ff1532d`.

| Source or binary | Bytes | SHA-256 |
|---|---:|---|
| `scripts/terrain/VoxelTerrainRuntime.gd` | 80,855 | `1a5e29076e40535f0b8ba1664612afc88fd224c94369720611dbeb255274680e` |
| `scripts/world/WorldStreamingCoordinator.gd` | 48,140 | `3f57679645595cfa48a8c2cc5fa49a0cfd22bcf42e571a5835b09f7f65c1efa6` |
| `scripts/world/CitadelPublicationService.gd` | 134,617 | `c82bb89abc862ad8b34459d925bedd51c0f68365a67c4d8222c7ab3c92348c7c` |
| `scripts/buildings/BuildingScenePublicationJob.gd` | 105,145 | `b734a2963127ad6b0ed64d49f8c623c06d35478553a58085e4616905889e94f8` |
| `scripts/world/GeneratedStructureRuntimeBindings.gd` | 12,886 | `0bf4f2ba09e81a1c6eb83ab91b16eceda44e8c4298b15657063fa8fdc05eda31` |
| `scripts/MainRuntimeTools.gd` | 119,122 | `ddb1dc0259ead2f57323b5596c8696041fb6caab0c2fb2f9a7b6d3ebdf21b38c` |
| `scripts/perf/RuntimePerformanceMonitor.gd` | 7,620 | `95611732e9cf4c1c6538b10c32a24e632b817a404247cacf7603fef26cf7742c` |
| terrain meshing debug DLL | 485,376 | `50e6004d539dff92f30e136f9a6298a32e4f3fda84dd522907015d8ee31e4571` |
| terrain meshing release DLL | 456,192 | `fb02febd19cc41ad32f0b9a793ce67689cb0ce290d01152d4979e7abc14959ee` |
| voxel editor DLL | 7,547,392 | `b24cc4eb8d22c27ce5babf1cf23190571d4acca9b2d215cf9c9adf00614bfc97` |

Engine/host evidence: Godot 4.6.1 stable Forward+, Vulkan 1.4.325, NVIDIA
GeForce RTX 5060 Ti, Windows, 1920×1080 for both headed measurements. Native
terrain binaries were not rebuilt or promoted during Gate 1.

## Gate decision and next action

Gate 1 lifecycle corrections are verified. G2 entry is permitted under the
explicit performance-pending exception, but release performance is not green.
The first G2 action is corrected-profile work on the immutable Citadel group
spatial/view index and demand-refresh call chain, followed by autosave snapshot
ownership. Gate 2 must not begin with native raster tuning and must not modify
the protected NPC routing stack. No push, merge or Gate 2 implementation was
performed here.
