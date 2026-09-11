# Retained spatial demand and nearby terrain coverage

Candidate after `e859367`, branch `codex/world-streaming-architecture`.

The user's September 11 clarification makes the 90-second startup target
provisional, with no replacement deadline selected. Report fresh-world creation,
saved-world Continue and ordinary traversal separately. Fresh process alone does
not establish an empty generated-artifact cache; record that cache condition
explicitly before calling a sample cold. Continue also needs a fresh process,
the same saved location and separately identified generated-cache state. The
64m physical/dependency contract and frame-pacing standards remain unchanged.
Keep complete-citadel time separate from playable-nearby time.

`WorldStreamingCoordinator` now owns bounded, explicit requests in half-open XZ
terrain-cell coordinates. It maps them to existing 28-cell gameplay chunks and
retains a 32-cell (43.2m) surrounding ring for ten seconds after release.
Overlapping owners release independently; world reset never reuses request IDs.
Request/residency limits reject new demand explicitly without deleting accepted
demand. Main retries current player/actor requests while capacity is unavailable.

Staged startup requests terrain extending 64m in each horizontal direction from
the player (a square containing the required 64m-radius circle), plus the existing
scenario requirements. Initial terrain loading waits for the existing native
mesh/collision proofs for all intersecting chunks. After startup, quantized
player demand and active NPC body demand take over before startup requests expire.
Terrain viewers retain groups of four gameplay chunks through the existing site
admission gate. Chunk removal releases gameplay publication records; retained
owners prevent premature release. World reset and shutdown remove the viewers.

The existing citadel publication pump merges retained rectangles and the observer
individually, never enclosing unrelated areas. Invalid replacements are atomic.
Its 16-site limit bounds residents, while unserved demand remains pending.
Construction still checks the ordinary occupied-player guard and source revision;
door/tree retirement still belongs to the existing balanced callbacks.

This is **not complete regional playable readiness**. The coordinator requires
terrain, structure and navigation owner acknowledgements; missing regional owners
return pending. Only terrain currently exposes the regional acknowledgement.
The current startup gate retains its existing structure and NPC navigation
semantics. Partial citadel checkpoints, support/crossing dependency closure,
ten-second traversal prediction, required route/scenario leases and complete
regional navigation acknowledgements remain necessary before that gate changes.
The initial explicit startup/actor requests must not be called a finished
scenario dependency inventory. No save-format or route execution changes.

## Focused evidence

- `StartupLoadingReadinessContractRunner.gd` through the existing Node owned
  watchdog: `artifacts/citadel-runtime-integration/retained-region-startup-01/`,
  16 checks pass, clean logs/exit/cleanup and zero owned processes. Added
  coverage is explicitly synthetic: grid boundaries, overlap, hysteresis,
  missing owner acknowledgements, capacity rejection and stale releases.
- `node tools/run-building-contract.mjs -Contract CitadelPublicationServiceContract.gd -ReportEnvironment CITADEL_PUBLICATION_REPORT -OutputDirectory artifacts/citadel-runtime-integration/retained-region-service-02 -TimeoutSeconds 120`
  passes 98 service/lifecycle checks, clean logs/exit/cleanup and zero owned
  processes. The first invocation found a new fixture passing an untyped array;
  the setter now validates and copies array elements explicitly, rejecting
  malformed input atomically rather than throwing at the public boundary.

## Early headed citadel run

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-retained-region-01
```

Passed diagnostic, clean logs/exit/cleanup, zero owned processes. No setup
teleports. Startup terrain waits for 16 chunks instead of the previous nine.
Current startup: **105.148s**, versus 80.048s in the prior surface-worker sample;
this is additional coverage, not a speedup. Entire diagnostic: 171.479s.
Source identity and near scene counts remain unchanged: 241,573 instances,
1,477 MultiMeshes, 739 other meshes, 3,280 collision shapes, 20 doors and 178
furniture bodies. No source binding or collision mismatch.

Inspected initial ground, pending publication, courtyard overview, gatehouse
landing and home door captures. Nearby terrain is continuous in those views;
distant walls are visible while the citadel completes. Courtyard layout and the
landing/door geometry remain visible, with the existing dark/grainy close-up
lighting limitation. Captures are diagnostic viewpoints, not proof of entering
every home or collision-backed stair/NPC traversal.

Short input approach: 956 intervals, p99 18.0ms / max 29.223ms, none above 33ms.
Scene publication: p99 32.6ms / max 42.890ms, 16 intervals above 33ms. Fixed
overview/courtyard/door views each have no interval above 33ms. Memory at fixed
views is approximately 1.36–1.38GB, higher than the previous sample. This is not
five-minute performance acceptance. Required broader observations follow below.

## Failed first runtime snapshot and batched follow-up

`retained-region-normal-01/report.json`, seed `atlas-45536858`: actual New Game
input to readiness 51.175s, 554.658m observed movement, 759 collision-mesh hold
frames, post-draw p99 65.2ms / max 95.521ms. The worst game-script section was
`terrain_meshing_job_queue`, 63.213ms. Watchdog `godot-ztIbiX` finished with clean
cleanup and zero owned processes; the performance result failed.

Source inspection found a critical **fixture limitation**: the normal observer
moved the player from the loaded spawn `(360.45,14.97,-13.5)` to a selected lane
roughly 270m away before traversal. Those holds cannot be attributed to ordinary
traversal from the loaded area. Previous ordinary-menu timings are still valid,
but previous traversal results are relocation-based stress observations. The
observer now starts at the actual spawn, removes lane selection/placement, saves
a spawn capture and reports its setup position. It also treats collision holds
as failures and retains at most 32 one-second hold samples with actual position,
collision proof, native task state and demand errors.

The batch also removes unnecessary diagnostic terrain-LOD selection from native
fluid-only jobs (exact fluid resolution stays one), instruments state setup,
throttles retained-viewer activation behind current collision coverage/native
task backpressure, and retains existing viewer coverage across handoff. Predicted
demand now looks ten seconds ahead using movement and facing. These scheduling
changes require the follow-up headed run; the first run does not verify them.

Final batch contracts so far: `retained-region-startup-02` 18/18;
`retained-region-bounds-01` 5/5; `retained-region-fluid-01` 13/13. They use the
existing startup watchdog, `run-terrain-meshing-bounds-contract.mjs`, and
`run-exact-fluid-payload-contract.mjs`, with reports in their named directories.
These are contract/service evidence only.

`retained-region-normal-02`, random seed `atlas-63983044`, reached real New Game
readiness in 37.861s and observed zero terrain hold frames. However, inspection
of its real-spawn capture and trajectory found the observer confined near the
starter house (only 8.50m final displacement). Its 61.91m accumulated travel does
not establish streaming coverage. The existing script p99 threshold failed at
22.037ms; this is threshold noise, not a reason for a production optimization.
Watchdog `godot-p7GwRT` exited naturally with clean cleanup and zero owned
processes. The next observer opens the generated door with a real view ray and
viewport input, acknowledges any dialogue through Escape, and walks outside
through player physics. It additionally requires a 64m excursion and at least
four visited chunks to prevent indoor movement passing as streaming evidence.

That indoor run also failed actual rendering cadence: p99 73.1ms, 657 intervals
over 33ms. Its 208.018ms maximum includes unseparated screenshot work. Later
captures have their own observation phase; their cost remains in overall cadence.
The small script-threshold failure must not obscure the much larger pacing issue.

`retained-region-normal-03`, seed `atlas-65391356`, reached startup in 40.912s.
Its new door setup incorrectly compared the hit child collider with the owning
door. The capture visibly showed the ordinary Open door prompt. The observer
now uses the existing `interaction_block_from_collider` identity resolver before
issuing input; no door implementation changed. Watchdog `godot-egJTAy` exited
naturally with clean cleanup and zero owned processes.

## Corrected headed traversal snapshot

```text
node tools/run-normal-runtime-performance-pass.mjs -Resolution 1920x1080 -DurationSeconds 75 -TimeoutSeconds 300 -ReportPath artifacts/citadel-runtime-integration/retained-region-normal-04/report.json -ProgressPath artifacts/citadel-runtime-integration/retained-region-normal-04/progress.txt
```

Screenshot environment `VOXEL_NORMAL_RUNTIME_PERF_SCREENSHOT` points to this
directory's `final.png`. Random seed `atlas-98803426`. New Game readiness:
**39.445s**. Actual spawn, real door opening and collision-backed exit; zero
setup relocations. The observer covered **535.626m**, reached **130.622m** from
spawn and visited **15 chunks**, with **zero terrain collision hold frames**.
Inspected the house-exit and final forest captures. Ordinary rain/night settings
remain active, so the dark forest view does not establish daytime visual quality.
This is a 75-second observation, not five-minute acceptance or a cold-cache claim.

Performance still fails: post-draw p99 **70.9ms**, maximum **262.896ms**, 719
intervals over 33ms and one over 100ms during traversal (capture separately
classified). Main-script maximum 29.082ms; measured rendering CPU p99 13.8ms,
GPU p99 20.1ms. Peak shadow primitives 125,608,936 and shadow calls 6,191 identify
substantial rendering load but do not by themselves explain the full cadence gap.
Watchdog `godot-vbv7Ry`: natural exit 1, clean logs/cleanup, zero owned processes.
This resolves the relocation/indoor fixture blockers and demonstrates streaming
without holds for this sample. It does not justify promoting performance.

Affected suites: `retained-region-nav-01` passes 84 cases / 178 assertions, clean
logs/exit/cleanup/zero (`godot-wL2zJw`). `retained-region-streaming-save-01` passes
40/42 cases; both failures require the absent generated latest world-signature
artifact. Its detached synthetic fixtures also emit the previously recorded
global-transform/world errors; watchdog `godot-9UzgOL` forces cleanup, proves zero
owned processes and reports cleanup failure. These exact fixture limitations were
already recorded in `WORLD_STREAMING_PACKETS_AND_INITIAL_SPAWN_2026-09-10.md`;
they are not evidence of a new route or save regression, and are not a clean pass.

Mandatory broad headless run, same baseline seed `atlas-1492`:
`retained-region-broad-01/report.json` records 82 passing checks but
`finished=false`. The watchdog stopped on `Initializing already initialized RID`,
null dummy mesh and renderer scene-cull errors during placement collision waits.
`godot-xkJsbu` reports forced cleanup, cleanup failure and zero owned processes.
The exact initialized-RID error chain also appears in pre-architecture watchdog
`godot-ayKzKO` (2026-09-09 22:15 UTC), independently read in this investigation.
`CITADEL_SHARED_COMPLETION_PROOFS_2026-09-09.md`, committed in ancestor `1f8814e`,
records this category and earlier baseline occurrences. This attributes the
existing headless failure category; it does not establish unchanged frequency or
complete broad coverage. A headed run of the same broad suite follows.

`node tools/run-playtest.mjs -Visible -Seed atlas-1492 -ReportPath artifacts/citadel-runtime-integration/retained-region-broad-headed-01/report.json -ProgressPath artifacts/citadel-runtime-integration/retained-region-broad-headed-01/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/retained-region-broad-headed-01/final.png -TimeoutSeconds 600`
finished **162/163**. Sole failure: the recorded `character_asset_pack_ready`
inventory mismatch (40 assets / 11 families). Save/load round trip, tutorial,
placement and screenshot checks passed. Final daytime terrain/dialogue capture
inspected; this broad fixture includes scripted setup and does not establish
ordinary traversal, real NPC route acceptance or Continue loading performance.
`godot-jkFRfF`: natural exit 1, clean logs/cleanup, zero owned processes. Full
run wall time 367.863s; that is suite duration, not a New Game or Continue timer.

The corrected observation runner and historical evidence correction are committed
as `e6f3271`. Production retained-region changes remain pending. Outstanding:
complete regional structure/navigation dependency closure, five-minute frame
pacing acceptance, matched fresh-process Continue timing and cold-cache campaign.
The clean headed broad exit attributes the headless failure to that run's renderer
path; it does not prove a fix for the pre-existing dummy-renderer resource defect.

## Source dependencies and first rendered terrain (September 11)

Building preparation now compiles spatial ownership and source support/anchor
dependencies on its existing worker. One owner per part, cross-cell references,
and the existing building/furnishing navigation manifests are retained by the
same one-shot preparation/publication/retirement holder. Queries describe source
requirements and explicitly do not acknowledge physical or navigation publication.
The ordinary terrain tile snapshot lacks complete citadel support/crossing topology;
that must be integrated before regional gameplay readiness can replace the old gate.

Existing Node building contracts: `spatial-dependency-preparation-01` passes 104
checks, including complete archived source/report parity, immutable containers,
negative owner boundaries, cyclic support closure, missing source IDs and cancellation.
Worker dependency compilation on that source: 281.735ms, 4,913 parts, 186 supports,
20 doors, 16 vertical links and 52 support seam links. `spatial-dependency-worker-01`
passes 64 ownership checks; `spatial-dependency-scene-02` passes 387 lifecycle checks.
All three have clean logs, cleanup and zero owned processes. Scene-01 failed parsing
in a new synthetic fixture's inferred WeakRef declaration; its corrected explicit
type is fixture-only and does not identify a production defect.

The full headed candidate `candidate-teleport-spatial-dependency-01` used the same
command as the earlier candidate above, with its own fresh output directory.
Known seed `atlas-3376622889`, initial cell `-3334,-2666`, zero setup relocations.
Startup 85.732s; whole diagnostic 163.095s; scene ready, natural exit 0, clean cleanup
and authoritative zero processes. Inspected spawn, courtyard, house doorway and
keep stair landing captures. Daytime door/stair views are very dark and courtyard
views hazy; this is not a complete visual-quality pass. Whole-site gameplay remains
`door_activation_pending`; scene readiness is not whole-site gameplay acceptance.
This sample does not establish a cold-cache or Continue result.

The user's next clarification explicitly requires keeping the loading screen until
the first nearby terrain is viewable. The existing mesh/collision readiness remains;
a final terrain-owned presentation barrier now also requires a visible terrain
owner, active visual viewer/camera, published spawn chunk and current body-area mesh,
then a completed rendering frame with the same seed/volume/publication state.
New Game, Continue and in-game New Game retain their loading UI and disabled movement
until this barrier completes. Missing readiness times out structurally. Headless
checks explicitly exclude visual presentation instead of waiting on an unavailable
draw signal. The title loading layer is above the new HUD; in-game loading is opaque.

`spawn-presentation-contract-02` passes all 18 existing startup checks, including
release ordering for the new presentation gate. This is contract evidence only.
The ordinary headed observer additionally requires the production presentation
receipt and captures the loading screen before its existing spawn/exit views.

`spawn-presentation-normal-01`: real main-menu New Game, random seed
`atlas-10003702`, 1920x1080, ordinary tutorial/night/weather settings. Command:
`node tools/run-normal-runtime-performance-pass.mjs -Resolution 1920x1080 -DurationSeconds 75 -TimeoutSeconds 300 -ReportPath artifacts/citadel-runtime-integration/spawn-presentation-normal-01/report.json -ProgressPath artifacts/citadel-runtime-integration/spawn-presentation-normal-01/progress.txt`,
with `VOXEL_NORMAL_RUNTIME_PERF_SCREENSHOT` pointing to its `final.png`.
The production presentation receipt precedes release, verifies volume revision
1367 and spawn chunk `(9,-1)`, and takes 8ms. New Game release: 40.2075s.
Inspected loading screen, initial house and ordinary door-exit captures; the
screen covers loading and the first gameplay view has the completed nearby scene.
The observer then travels 507.475m. Performance remains failing (script p99
23.006ms exceeds this runner's 22ms threshold); do not call the whole performance
suite passed. Watchdog `godot-kHSe32`: natural exit 1, clean logs/cleanup and zero
owned processes. Continue is wired through the same presentation barrier but a
headed Continue run remains outstanding; this sample is not cold-cache evidence.

The preceding citadel diagnostic's accepted-source SHA256 is unchanged:
`dbe543f28dfe876f28ae8611d7e869f07975f69e09067b2fe5c88d56e3e4b042`.
Scene counts match the committed near-detail baseline: 241,573 instances, 1,477
MultiMeshes, 739 meshes, 3,280 collision shapes, 20 doors and 178 furnishings.
