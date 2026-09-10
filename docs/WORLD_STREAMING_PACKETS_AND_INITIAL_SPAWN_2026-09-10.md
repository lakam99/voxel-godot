# Prepared masonry and initial-location measurement

Branch: codex/world-streaming-architecture, following measurement commit ff7c6a6.
This is the first portion of the building-publication cutover, not completion of
the spatial streaming architecture or performance acceptance.

## Production change

The existing owned publication worker now prepares immutable masonry instance
segments: final transforms, per-instance appearance, float32 upload values,
material requests and bounds. Deeply readonly dictionaries/typed arrays prevent
callers from mutating prepared data. The publisher preserves virtual material
hooks and their original first-request order. Aperture-cut geometry continues
through its existing authoritative cut-artifact path.

Static batches assemble at most 256 prepared instances per resumable unit and
submit one MultiMesh buffer per existing completed batch. Completed-part flush
boundaries, source bindings, physical geometry, interaction identities, metadata,
one-shot consumption, cancellation and worker retirement remain in place.
Full cell grouping, complete reusable packet identities, all geometry families,
regional readiness, LOD and occlusion are subsequent cutovers.

The 256-instance conversion does not mathematically bound cumulative buffer
reallocation or the final engine upload to 4ms. Their actual costs are measured.
The existing cooperative budget remains unchanged.

## Focused evidence

All directories below are under artifacts/citadel-runtime-integration.
These are contract/service evidence, not live gameplay acceptance.

| Runner/report directory | Passing checks |
|---|---:|
| prepared-masonry-packets-04 | 189 |
| static-packet-upload-03 | 140 |
| packet-scene-job-03 | 378 |
| packet-door-lifecycle-01 | 414 |
| packet-tree-retirement-01 | 305 |
| packet-aperture-01 | 185 |
| publication-worker-packets-01 | 62 |
| candidate-continuation-packets-01 | 26 |

Prepared/static contracts compare exact transform/custom-data order against the
pinned previous publisher, mixed raw/prepared batches, effective repair material
parameters and native buffer submission. Lifecycle contracts cover stale source,
replacement, cancellation, weak ownership and retirement.

Initial synthetic failures were fixture parse/type annotations and a cancellation
fixture waiting for the superseded per-instance collect stage. They were repaired
without changing production acceptance. Final reports above passed and owned
processes were cleared.

## Headed publication comparison

Command:

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-packets-01
```

Passed, natural exit 0, no engine warnings/errors, authoritative ownedZero.
Compared with candidate-teleport-architecture-baseline-01:

- Exact accepted-source SHA256 remains
  1f07667654652dbb53a4fb6107352d8fd1186ff79594b96563562f14ff5032f7.
- Both publish 5,934 nodes, 739 meshes, 1,548 MultiMeshes, 241,573 instances,
  all 3,253 source colliders and 3,280 total collision shapes.
- Prepared packet collection: 3,534 calls / 23.890ms total / 0.114ms maximum.
  Previous individual masonry collection: 187,250 calls / 568.952ms total.
- Static assembly: 30,248 calls / 77.188ms total versus 211,105 / 252.709ms.
  New engine uploads: 1,355 calls / 7.228ms total / 0.162ms maximum.
  Largest-cost recorded group/upload detail: 7,385 instances.
- Total publication advance CPU is 12.007s versus 11.839s. This sample does not
  demonstrate an overall publication speedup. Maximum atomic work is still
  26.108ms; remaining validation/publication work exceeds the cooperative slice.
- Publication cadence p99 21.9ms, maximum 82.125ms, ten frames above 33ms
  versus baseline p99 21.7ms, maximum 81.124ms, six above 33ms. Neither run
  establishes interruption-free acceptance; no broad pacing improvement claimed.
- Sampled engine static memory maximum during publication: 1,195,569,296 bytes.
  This is not process/GPU memory or a guaranteed transient peak. Baseline lacks
  that metric, so no comparative memory claim is possible.

Inspected ready, courtyard overview and gatehouse stair-landing images. Citadel,
terrain, trees, roofs and landings remain visible. Heavy grain in shadows and
dark close views remain baseline issues. These captures do not prove every
doorway, interior, furniture interaction, structural support or NPC route.

## Initial spawn instead of teleporting

The user's correction is implemented as an optional -SpawnCell x,z in the
existing runner. It requires an explicit CandidateRegion and SkipTutorial,
since tutorial scenario placement owns a different initial location.

The fixture selects the initial cell through find_spawn_position before attaching
the player and before terrain runtime creation. Height comes from the ordinary
authoritative surface query plus the existing five-metre spawn offset. It does
not load a source artifact, create terrain, certify a candidate or inject a site.
There are no subsequent setup teleports or setup physics freezes in this mode.
Production startup owns collision readiness and physics release. The runner
rejects a changed horizontal spawn or any fixture placement.

Fresh-process command, using the exterior cell observed in the earlier run:

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-initial-spawn-01
```

Result: all 27 checks passed, zero setup placements, natural exit 0, no engine
warnings/errors, authoritative ownedZero. Initial placement evidence confirms
beforePlayerAttachment=true and beforeTerrainRuntime=true; horizontal position
survives startup. New userdata is isolated and generated source is rebuilt.

- Current startup readiness/control release: 83.373s.
- First sampled full scene-ready: 134.274s.
- Ordinary collision-backed approach and diagnostic captures complete: 159.283s.
- Approach cadence: 947 samples, p99 17.0ms, maximum 26.806ms, zero above 33ms.
- Publication cadence: p99 22.8ms, maximum 74.287ms, 12 above 33ms.
- Startup still includes a 2.805s maximum cadence stall.
- Exposed worker masonry preparation: 6.640s; history preparation: 24.955ms.

The complete source file hash differs because its binding sourceKey differs.
source-byte-comparison.json independently compares both 3,382,428-byte files:
the sole difference is the unique 64-byte binding key at offset 132. Replacing
that key in a comparison copy makes the complete files byte-identical. Blueprint
and furnishing contents, source signature and all scene/collision counts match.
The binding remains unmodified in production and in original evidence.

Inspected initial-spawn ready and home-door captures. The citadel appears on
terrain with foliage; the door approach remains clear but poorly lit.

This diagnostic invokes the production deferred New Game scene directly; it
bypasses the title UI and uses explicit scenario/lighting flags. Its timer begins
before scene instantiation. It does not prove flag-free menu New Game/Continue,
the new 64m regional dependency contract, five-minute traversal, cold-load
repetition, interior interaction or NPC acceptance. Full citadel scene readiness
must not be reported as complete gameplay readiness. The existing
gameplayReady=false / door_activation_pending label is unchanged.

Node runner tests: 15/15, including initial-spawn argument validation.
Add -ManualInspection to keep ordinary controls available after scene readiness.
Use a fresh candidate-teleport-* output directory for every invocation.

## Remaining milestone gates

Full architecture and performance acceptance remain open.

Mandatory broad command:

```text
node tools/run-playtest.mjs -Seed atlas-1492 -ReportPath artifacts/citadel-runtime-integration/packet-broad-01/report.json -ProgressPath artifacts/citadel-runtime-integration/packet-broad-01/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/packet-broad-01/final.png -TimeoutSeconds 600
```

This deliberately replays the recorded failing baseline seed. Finished=true,
161/163 passing. character_asset_pack_ready (40 assets/11 families) and
screenshot_saved fail, matching two recorded baseline defects in
CITADEL_NATIVE_SUPPORT_INTEGRATION_2026-09-10.md. The previously failing NPC
home/guard assertion passed this sample; that does not establish live NPC
acceptance. Synchronous save/load chunk reconstruction still visibly dominates
elapsed test time. Headless screenshot errors required watchdog cleanup:
artifacts/node-tools/process-runs/godot-sKrmL6/watchdog.json records
forcedCleanup=true, cleanupPassed=false, authoritativeZeroProven=true.
This is a failed broad run with attributed baseline failures, not a clean pass.

Affected NPC suites, all with -TimeMode Both and isolated report/progress/trace
paths beneath the listed directories:

| Command | Directory | Outcome |
|---|---|---|
| node tools/npc/run-npc-contract-tests.mjs | packet-npc-contract-01 | 84/84, natural exit and clean ownedZero |
| node tools/npc/run-npc-nav-world-tests.mjs | packet-npc-nav-world-01 | failed engine error, incomplete report, forced cleanup/ownedZero |
| node tools/npc/run-npc-streaming-save-tests.mjs | packet-npc-streaming-save-01 | 40/42 plus engine errors/leaks, forced cleanup/ownedZero |

Watchdogs respectively: godot-fTmFgh, godot-0W3r1U, godot-48Ai2r, under
artifacts/node-tools/process-runs. Navigation's fake main and collision nodes
are never attached to the scene tree before querying global transforms.
Streaming/save's fake main likewise invokes get_world_3d while detached and
leaks physics bodies. Its two failed assertions are the day/night copies of
npc_save_world_signature_unchanged: the expected generated latest artifact is
absent. This does not establish a changed world signature.

The implicated fixtures and production NPC adapter/placement/lifecycle files are
unchanged from 2c71199, and these failing cases do not invoke the changed building
publication path. Existing baseline exceptions are documented in
CITADEL_RUNTIME_INTEGRATION.md and signature failures in
tutorial_town_loading/PHASE_6_SAVE_CONTINUE_COMPATIBILITY.md. No protected NPC
code or test standards were changed. These failures remain outstanding coverage;
neither source parity nor the clean headed diagnostic overrides them.
Unchanged files establish that these fixture paths predate this milestone, but
do not independently reproduce the exact prior engine-error outcome. No exact
baseline replay of those NPC engine errors is claimed. Scoped milestone review
found no demonstrated new production blocker; 90s/60FPS acceptance stays open.
