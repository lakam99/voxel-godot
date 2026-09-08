# Citadel production-path inspection — 2026-09-08

Worktree: `voxel-biome-world-godot-citadel-visuals`, branch `codex/citadel-visuals-clean`.
Production fix: `52e2d31` (keep bunting). Seed `atlas-3376622889`, region `(-2,-2)`, recipe `1393179273`.

## Passing prerequisites

`node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-23 -Seed atlas-3376622889 -CandidateRegion '-2,-2' -ExpectedRecipeSeed 1393179273 -ExpectReady`

Public Recipe passed in 291.004 seconds; independent physical validation in 9.002 seconds checked all 4,702 parts with zero violations. Furniture snapshot contains 178 parts; this does not prove furniture gameplay or appearance. Natural exit 0, clean owned-process zero, frozen sources unchanged.

- Source SHA256: `d42e865f39b5142e7e1582f566858b1c997364b31100c54fd072b956e18db70e`
- Input SHA256: `c92d1010cfde53b23fd165c44bd3015ee07121ef2305c2c90f14d3dc67d8a385`

`node tools/run-citadel-candidate-integration-continuation.mjs -SourceDirectory artifacts/citadel-runtime-integration/candidate-recipe-23 -OutputDirectory artifacts/citadel-runtime-integration/candidate23-integration-01`

24 checks passed: exact artifact restoration, actual ordinary site/terrain admission, source-bound terrain profile, CPU publication preparation, all 3,214 static-record bindings, 1,419 masonry records, history identity and exact furniture preservation. All 87,009 terrain columns surveyed. Natural exit 0, no engine warnings/errors, owned zero; before/after evidence inventories unchanged. This is service readiness, not live publication acceptance.

Source signature: `0cfd1e3c8a49292b82073f983c835dad6046035f6ba8860bbb2c54b77d35fc8d`.
Reservation: origin `(-3483,-2961)`, size `(299,291)`, level `41.85`.

Read-only critic explicitly granted GO for early headed Main inspection after these combined prerequisites.

## Headed evidence and independently detected defects

Common command:

`node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion '-2,-2' -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/<attempt>`

The existing fixture instantiates Main.tscn with a seed-selector-only subclass and ordinary New Game startup. Two exterior teleports are setup only; player physics is paused pending native collision/capsule readiness. No NPC/traversal acceptance is inferred.

### candidate-teleport-23-01

Interrupted at approximately 82 seconds by watchdog `EPERM` replacing `live-ownership.json`. No engine errors, timeout or production rejection. Forced cleanup, authoritative zero; not a clean functional run. Saved `preteleport.png` and `pending.png` inspected. The live view was dark while source preparation was pending.

Runner repair: retry only transient replacement errors three times, 20ms apart, refreshing authoritative job membership and owner identity before each new receipt. Persistent errors still terminate. Existing watchdog suite plus injected transient/persistent failure coverage: 18/18, reports under `C:/Users/arkam/AppData/Local/Temp/owned-watchdog-tests-E4ZKGD`. These are runner tests, not gameplay acceptance.

### candidate-teleport-23-02

Natural exit 1 at 403.8 seconds; no engine errors/warnings, source changes or forced cleanup; authoritative zero. **Production source generation/admission succeeded**, with the same source signature and reservation as the prerequisites. Scene construction had not started.

Terminal fixture failure: `accepted_source_owners_missing`. Its eager owner list required `Main.tree_publication_queue`. Production intentionally creates that queue on the first procedural-tree submission (`ensure_tree_publication_queue`), so a treeless startup need not have one. Corrected the fixture to observe/pin this lazy owner when it appears and reject later replacement/loss; terminal tree observations still require the queue. Required eager owners now report their missing key instead of discarding that diagnostic.

Existing `CitadelTeleportSelectionContract.gd` passed 23 checks, with clean parse, engine logs and owned zero, in `teleport-lazy-owner-regression-01`. This checks fixture selection/parsing only, not the new lifecycle through real publication.

The user's screenshot showed fragmented stepped terrain during source preparation, with zero constructed citadel scenes. It is not a completed citadel view. The long wait and poor nighttime readability are observed limitations; the fixture's suspended player and remote placement must not be represented as ordinary traversal behavior.

### candidate-teleport-23-03

Stopped at the user's request to add explicit launch options. The run-local stop request terminated only the owned job and proved zero remaining members. This is an intentional interrupted run, not candidate acceptance or a production failure.

## Explicit launch options

Normal game launches retain the tutorial and ordinary clock/weather. For direct Godot launches, pass session options after `--`: `-SkipTutorial -ForceDaytime -ForceClearWeather`.

The headed Node runner now accepts the same switches. `-SkipTutorial` skips the scenario for a new world while retaining ordinary spawn, terrain/collision readiness, world generation and NPC systems. Continue preserves the saved tutorial state. `-ForceDaytime` holds the ordinary clock at noon; `-ForceClearWeather` uses the existing weather authority to hold clear skies without precipitation. These options are recorded explicitly and are not tutorial/night/weather acceptance.

Example:

`node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion '-2,-2' -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-23-04`

Startup has a separate 120-second ceiling by default (configurable 15–180). The 600-second test allowance begins only after startup succeeds and reserves 45 seconds for ordinary shutdown. The outer owned watchdog is bounded by the sum (720 seconds for this example). Reports separate startup and test elapsed time and verify observed launch settings. This does not remove or conceal the measured multi-minute citadel generation cost.

Focused verification: `node --test tools/tests/citadel-candidate-runners.test.mjs` passed 15 tests. `GameLaunchOptionsContract.gd` passed six parsing/default/clock checks, clean engine logs and owned zero, under `game-launch-options-01`.

### candidate-teleport-23-04

The critic approved the explicit flag run with separate 120/600-second clocks and overall 720-second watchdog. Main verified all three requested options. Inspected `preteleport.png` shows 12:00/Clear, ordinary outdoor spawn and no tutorial scenario. Startup: **19.629 seconds**, versus 38.7 seconds in the earlier tutorial run. Test elapsed: **402.098 seconds**.

Production source admission succeeded with the same validated source signature. Both setup placements, accepted-owner/source identity, native terrain mesh readiness, five collision-backed surface samples and two fresh physics frames of capsule clearance passed. Player physics resumed and remained outside the reservation. The lazy queue fix therefore cleared its previous gate.

**Actual production blocker:** `building_preparation_timeout`, from the scene-publication worker's own 60-second preparation limit, still in `physical_resolve_support` after 1,032,723 callbacks. No scene was constructed. This is distinct from the outer test/watchdog timers, the earlier receipt-write error, and the earlier fixture ownership failure. Do not raise the watchdog or rerun unchanged; investigate preparation cost and all independent defects in this snapshot together.

Main report: `artifacts/citadel-runtime-integration/candidate-teleport-23-04/report.json`. Natural functional exit 1, no engine errors/warnings, frozen sources unchanged, clean cleanup and authoritative zero. All four saved captures inspected; no completed citadel visual/furniture/tree acceptance. Native collision proof covers the exterior setup location, not all citadel geometry. The failed capture records the exterior terrain while construction is absent.

## Preparation cost repair

The existing continuation now also exercises the real `BuildingPublicationWorker.RunState` callback, inside its owned worker, while retaining phase/deadline measurements. `candidate23-worker-cost-01` passed all 24 checks: preparation 30.415s, physical 10.106s. The worker callback therefore does not alone reproduce the live slowdown. Existing stage measurements identify repeated physical support resolution as the dominant cost; both required resolution passes remain.

`BuildingBlueprint.structural_support_at` now omits the preferred-candidate pass only when its required-ID set is empty, checks cheap membership/exclusion before structural eligibility, and computes invariant target bounds once per point. Candidate ordering, support selection, all physical predicates, cancellation and geometry remain unchanged.

`BuildingValidationCacheContract.gd` passed 75 checks under `support-pass-regression-01`. Exact candidate continuation `candidate23-worker-cost-02` passed all 24 readiness checks, clean logs/exit and owned zero. Preparation fell to 23.729s; physical validation to 5.913s. Its complete 4,702-part physical report, route geometry report and readiness checks compare exactly with cost-01; pinned report hashes and comparison receipt are in `candidate23-worker-cost-02/exact-comparison.json`. No production timeout was increased. Live performance and scene publication still require the next headed run.

### candidate-teleport-23-05 and remaining preparation work

Headed05 at `697e23f`, using the same flag command and 120/600-second clocks, again admitted the exact source. Physical validation completed, but the production worker reached 60.034s in `publication_masonry_cursor` and failed with `building_preparation_timeout`. Zero citadel scenes constructed. Natural exit 1, no engine errors/warnings or source changes, no forced cleanup, authoritative zero. Inspected `failed.png`: ordinary exterior terrain/trees at noon and clear weather, no citadel. This is a production timeout, not a synthetic fixture failure.

The next batch removes a per-call eligibility Array allocation from support checks and removes the masonry custom-data cursor's unused extrema scan and per-brick math. Colors still derive from the same history queries in the same order; geometry, validation and cancellation remain intact.

Existing `MasonryDescriptorGeometryContract.gd` passed 327 checks against its frozen independent oracle, including exact descriptor bytes, history-query order and cancellation (`masonry-dead-work-regression-01`). `BuildingValidationCacheContract.gd` passed 75 checks (`support-pass-regression-02`). Exact continuation `candidate23-worker-cost-03` passed 24 checks, with complete physical/route/check equality against cost-02 recorded in `exact-comparison.json`. All exited naturally with clean logs and owned zero. Measured preparation was 17.657s, physical 4.344s, masonry 5.059s versus cost-02's 23.729s, 5.913s, 7.109s; these isolated measurements do not establish live performance. Critic PASS and conditional GO requirements for headed06 satisfied. Production deadline remains 60s.

### candidate-teleport-23-06 and live slowdown diagnosis

Headed06 at `11d0f2b` admitted the same source, but again failed `building_preparation_timeout` after 60.046s in masonry, with 1,261,191 callbacks and zero scenes. Total elapsed 337.186s. Natural exit 1, clean engine logs, unchanged sources and authoritative zero. Inspected `failed.png`: ordinary outdoor terrain/trees, no citadel. Reduced isolated work did not resolve the live blocker.

Read-only comparison found the same preparation/restoration/cancellable-validation path, no live-only cache bypass, and no measured owner polling stall (worker max poll 64us, service max advance 492us). Worker-side waiting/CPU contention remains unproven. A concrete flag defect was found: forced clear weather called the existing scripted weather API, which always updated stars with night factor, producing `starsVisible=true` at noon and 160 star transform writes per frame. The clear-weather caller now supplies actual daylight; the optional API argument preserves other scripted callers.

`game-launch-options-02` passed 11 parsing/clock/direct-weather-service checks, including clear daytime hiding stars without changing star transforms, clear nighttime stars, no precipitation, and unchanged legacy scripted defaults. `publication-worker-phase-timing-01` passed 62 existing synthetic worker checks. Both exited cleanly with owned zero. The worker now reports only six bounded phase durations; the headed fixture records the existing runtime performance monitor once per second and at termination, and checks noon stars are hidden. These are observations, not new acceptance exemptions. Critic PASS and GO for headed07 to verify the flag correction and measure the live bottleneck, with unchanged 120/600-second clocks and 60-second production deadline.

### candidate-teleport-23-07: preparation cleared, aperture publication failed

At `bebd0e7`, headed07 verified all launch settings, including hidden noon stars, admitted the exact source, completed preparation within the unchanged 60s allowance, and started one scene. It failed at 333.540s total with `masonry_cut:clipping:unrepresentable_centered_aperture`; no scene completed. Natural exit 1, clean logs, unchanged sources, authoritative zero. `failed.png` inspected: ordinary exterior terrain, no completed citadel. Live observed route-geometry phase was 25.961s (includes its support-resolution pass); terminal worker progress is empty after retirement. Terminal game-loop monitor window max was 13.004ms and p95 10.08ms; section maxima: chunk 9.027ms, wildlife 6.273ms, external autosave write 5.602ms. This is stationary setup observation, not traversal/performance acceptance. The attempted post-preparation OS CPU sample occurred after exit and is explicitly marked invalid; do not infer CPU deltas from it.

The batch cut diagnostic restores the pinned Candidate23 source and enumerates all 112 marked wall parts and 4,445 regular/repair bricks through actual descriptors and per-brick cut preparation. `candidate23-aperture-inventory-04` found only two failures: `urban_row_01_left_upper_facade_013` and `_015`. Exact inputs are in `failures.bin`, with endpoint evidence in the report. This completed diagnostic did not establish readiness. Inventory01 failed due to a diagnostic-only omitted furniture reservation field; inventory03 failed parse due to diagnostic-only inferred vector types. Both cleaned to zero; neither is a production defect.

The clipping authority now chooses a deterministic exact construction origin per axis before clipping: retain the brick centre where every relevant declared plane translates exactly, otherwise leave that axis untranslated. Original aperture sizes preserve untranslated endpoints. Solid-origin translation is checked exactly. There is no epsilon, changed opening, altered publisher frame or retry after failed geometric verification; final original-frame vertex/cell guards remain intact.

`candidate23-aperture-inventory-06` completes the same full inventory with zero failures and checks aggregate publication limits. Existing geometry contract passed 196 checks (`masonry-frame-geometry-02`), including independent emitted-vertex clearance/local containment for the formerly unrepresentable translated endpoints. Existing publication contract passed 185 checks (`masonry-frame-publication-01`). All natural clean exits and owned zero. The earlier geometry01 failure was its obsolete expectation of rejecting those two synthetic endpoints; it was replaced by stronger exact-output checks, not an exemption. Critic PASS and headed08 GO prerequisites satisfied. This is CPU cut/publication contract evidence, not a completed visible citadel.

### candidate-teleport-23-08: scene constructed, visual verification still absent

At `a33c7a6`, the actual Main scene completed publication in 385.521s total (startup 18.061s). Natural exit 0, all 21 fixture checks passed, no engine errors/warnings or source changes, authoritative zero. Scene audit: 6,065 nodes, 767 meshes, 1,673 MultiMeshes / 242,135 instances, 3,258 collision shapes, 178 furnishing bodies, 20 registered doors, four published/registered procedural trees. Eight native collision probes passed. Root matched its source profile at `(-4500.9,41.85,-3800.25)`. These establish constructed/registered scene contents, not all collisions, furniture interaction or visual quality.

**Inspected `ready.png` does not show a recognizable citadel. Goal remains incomplete despite the runner's pass.** `door_activation_pending` / `gameplayReady=false` is hardcoded by `scene_state`, not a visibility gate; NPC/navigation activation remains deferred, not silently accepted. The framing check only verified player yaw. The camera was roughly 284m from the root and 25.5m below its base. Terrain occlusion was plausible but unproven. Stationary terminal game-loop window max 6.78ms/p95 6.351ms; maximum publication step 27.082ms. No traversal/performance acceptance.

The fixture now selects the highest ordinary-ground side midpoint of the accepted reservation for its second exterior placement, retaining the two-write limit and all native collision/capsule checks. It collects root/mesh visibility, actual transformed mesh/MultiMesh bounds and representative layers/ranges. Ordinary mouse input aims yaw and pitch at those bounds. The final snapshot includes active camera identity/transform/projection/cull mask plus projected/frustum points, first collision-ray hits and authoritative terrain heights at nine bounds samples. These sampled observations do not replace screenshot review. Existing selection contract passed 23 checks (`teleport-framing-01`), proving parse/selection only; new framing needs the live run. Critic PASS and headed09 GO with unchanged identity, flags and budgets.

### candidate-teleport-23-09: visible production citadel

At `59a4295`, headed09 passed all scene/identity/collision checks in 379.203s total, with natural exit 0, clean engine logs, unchanged sources and authoritative zero. The inspected `ready.png` clearly shows crenellated towers and their connecting curtain wall beyond the foreground trees. Critic scoped PASS: production spawn and distant exterior silhouette verified, no blocking visual defect evident at this distance. Haze and foreground trees limit detail; close masonry/ground contact, interiors and furniture interaction are not established.

The active camera is the player's, with all nine visual-bounds sample points inside its frustum. All 2,440 geometry instances are visible in the scene tree. World bounds: position `(-4569.504,41.85,-3864.945)`, size `(136.5093,29.6457,125.6008)`. Centre/corner rays record foreground tree/terrain obstruction and one actual citadel collision hit. Authoritative sampled ground at the structure is approximately 41.85, matching its base. Construction contents match headed08 (178 furniture, 20 doors, four trees, 3,258 collision shapes). Terminal stationary game-loop window max 6.694ms/p95 6.239ms; this is not traversal/performance acceptance.

For close exterior inspection, the existing fixture now follows successful construction and the distant ready capture with at most 45s of ordinary W/Shift input. It retains two setup teleports, requires ordinary player physics (no automated-movement property), stops within 8m of actual visual bounds, and may sidestep briefly when motion stalls. All keys are released on normal completion and terminal paths. Position, sprint/key state, existing performance observations, identity and terminal capsule/ray evidence are recorded; failed approach remains a failed run with the distant capture retained. No NPC/navigation or production behavior changes. Parse/selection contract passed 23 checks (`teleport-approach-01`); critic PASS and headed10 GO with unchanged budgets. Proximity alone is not close visual acceptance.

### candidate-teleport-23-10: production spawn passed, approach incomplete

At `cf7979f`, the same source and scene constructed, but the ordinary-input approach stopped approximately 95.145m from its visual bounds at `(-4513.394,24.03023,-3644.199)`. The 45.028s approach ended with `approach_time_limit`, total run 426.242s. Identity and terminal capsule clearance passed; all keys released. Natural exit 1, no engine errors/warnings, frozen sources unchanged, authoritative owned zero. Inspected `close.png` clearly shows the fortress silhouette beyond ordinary terrain and trees, but remains too distant for close exterior/interior/furniture acceptance. This is a failed approach fixture, not failed citadel generation/publication; its trace does not identify the motion blocker.

The existing approach now observes native slide contacts, player velocity/grounded state, the existing terrain collision proof and authoritative ground height. A stalled approach tries a brief ordinary jump, then a pure lateral step (alternating sides) instead of continually pressing forward into the obstacle. The same 45s act limit, two setup placements, identity/capsule checks and terminal key release remain. No production movement or navigation code changes. These observations distinguish an ordinary obstacle from a terrain-readiness hold without assuming either is the cause.

### candidate-teleport-23-11: ordinary approach passed

At `b2b281a`, all 21 checks passed in 393.439s. Approach: 13.029s, 7.895m from actual bounds, one ordinary jump, no lateral recovery needed. At the first stall native slide contacts identified a chunk StaticBody3D with a horizontal contact normal; the jump cleared it. All sampled terrain proofs were ready, with no terrain hold. This establishes a world-prop obstruction on this route, not a terrain-readiness failure or justification to change the shared motor. Source identity, capsule clearance and released keys passed. Natural exit 0, clean engine logs, unchanged frozen sources, authoritative zero.

Critic inspected `ready.png` and `close.png`: scoped PASS for production spawn and ordinary-input exterior approach. Close view shows continuous wall/battlements but masonry is poorly readable in shadow and a foreground rock obscures part of the base. It does not prove a hole, floating wall or terrain seam defect. Courtyard/roofline/furniture visuals remain uninspected. Sampled approach game-loop max 9.077ms, p95 at most 6.35ms; excludes complete rendering/physics-frame acceptance.

The next visual batch adds labelled diagnostic-camera views of the same constructed Main scene after the player approach: four exterior quarters, courtyard overview and two recipe-furniture samples. Camera positions derive from observed geometry bounds/actual furniture bodies. They do not move the player, change generated geometry or clock/weather settings, or prove access/interaction. Main may update camera-dependent environment effects from the diagnostic observer position. The ordinary camera is restored before completion. Keep these images distinct from the player captures and assess obscured views honestly. Existing selection/parse contract passed 23 checks (`teleport-inspection-01`), Node runner tests passed 15; critic PASS and GO for headed12 at unchanged budgets.

### candidate-teleport-23-12: production spawn visual sign-off

Command, from this worktree:

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion '-2,-2' -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-23-12
```

At `d7ff171`, all 22 checks passed in 391.487s (startup 18.079s). The production-generated source retained signature `0cfd1e3c8a49292b82073f983c835dad6046035f6ba8860bbb2c54b77d35fc8d`. The ordinary approach reached 7.975m from actual bounds in 12.963s. Both setup placements, source/owner identity, native scene collision observations and player clearance passed. All captures saved; the ordinary player camera was restored. `verification.json`: natural exit 0, no engine errors/warnings, no changed frozen sources, no forced cleanup, authoritative owned zero.

Inspected `ready.png`, `close.png`, all four `overview_*.png`, `courtyard_overview.png`, `furniture_5.png` and `furniture_6.png`. The diagnostic views show the keep, surrounding houses, varied roofline, paved courtyard, continuous curtain walls and towers. Furniture samples show recipe-produced candle/plant window decoration. The read-only critic returned **PASS for the scoped production-spawn objective on this candidate**, supported by the ordinary player approach. No independently demonstrated missing major structure, broken roof assembly or floating building blocks that result. This completes the handoff's production-spawn milestone; no unchanged full rerun is warranted.

Remaining limitations are explicit: haze/dark shading flatten visual detail; full perimeter ground contact is only partially visible; detached cameras expose terrain outside the stationary player's streamed area, which does not establish a live terrain hole. Window ornaments do not establish furnished-room quality. Interior access, furniture interaction, door/NPC activation, broad seed coverage and full performance acceptance are not claimed. NPC/navigation remains deferred as required by the handoff.

Approach samples report game-loop max 8.093ms, p95 at most 6.296ms and no recorded spike reason. Cumulative section maxima include chunk 9.388ms, wildlife 7.623ms and external autosave write 6.267ms; these cover different observation windows and are not additive. Renderer/complete physics-frame performance is not established. Multi-minute generation remains a measured limitation, not concealed by the startup-only clock.
