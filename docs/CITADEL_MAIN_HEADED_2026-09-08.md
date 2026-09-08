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
