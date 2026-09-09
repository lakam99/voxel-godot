# Citadel structural repair — 2026-09-09

Worktree: voxel-biome-world-godot-citadel-visuals; branch codex/citadel-visuals-clean.
Prior work committed as f882299 before these repairs. Replay seed atlas-3376622889, region (-2,-2), recipe 1393179273.

## Repairs

- Residential house generation no longer emits incidental market awnings/shelves/goods into narrow streets. Dedicated market layouts remain. Door local width/thickness and frontage rotation now match the shared door publisher, removing oversized frames/query depth and wrong hinge orientation. Hood/sign producers consume that same orientation. Household storage/firewood avoids door approaches and settles on actual retained foundation/paving; unsupported objects are omitted without deleting supported household dressing.
- The upper street now has a grounded lane from the final stair endpoint to the upper house row. The captured previous source had a 1.46976-unit unsupported drop.
- Switchback landing supports use rooted outer posts and a two-seat underframe instead of full-width piers that blocked lower exits. Landing depth closes the captured exit gap. Seat validation retains strict contact requirements and negative controls.
- Keep stairwell placement derives from actual composed palace/rear-wing collision envelopes, including roofs. Floors, openings, stairs and room access share the result. An impossible layout fails generation instead of publishing a partial keep. This fixes additional intersecting floor framing/roof defects discovered in candidate25.
- A review caught an early return hiding the existing noncolliding keep banner. After headed26 finished and cleanup was proven, the unchanged banner emission was restored. The final focused contract compares its size/position with source25 and verifies collision remains disabled. Headed26 predates this decorative restoration.

## Verification

All paths below are relative to the project root; each output directory includes reports and ownership/cleanup evidence.

```text
node tools/run-building-contract.mjs -Contract StreetHouseOpeningLayoutContract.gd -OutputDirectory artifacts/citadel-runtime-integration/structural-opening-04 -ReportEnvironment STREET_OPENING_LAYOUT_REPORT -TimeoutSeconds 60
node tools/run-household-sign-placement-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/structural-sign-02
node tools/run-building-contract.mjs -Contract CitadelStairClearanceContract.gd -OutputDirectory artifacts/citadel-runtime-integration/stair-clearance-07 -ReportEnvironment CITADEL_STAIR_REPORT -TimeoutSeconds 60
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-26 -Seed atlas-3376622889 -CandidateRegion '-2,-2' -ExpectedRecipeSeed 1393179273 -ExpectReady
node tools/run-citadel-candidate-integration-continuation.mjs -SourceDirectory artifacts/citadel-runtime-integration/candidate-recipe-26 -OutputDirectory artifacts/citadel-runtime-integration/candidate-continuation-26
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion '-2,-2' -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-26-01
```

Opening contract 91/91; sign contract 17/17; final stair/composed-keep contract 45/45; continuation 24/24. These are producer/service/physics contracts, not player traversal acceptance. Final runs exited cleanly with owned process count zero.

Candidate26 full production generation/physical checks passed (~218 seconds). source.bin SHA256: 7c2047c45b51f05dbd99c4747c9bde63c8184eb50140c5b46af2bb67179ca70e.
Independent read-only review found 32 inspected building bases grounded, 81 supported/clear upper-lane samples, and a 0.015-unit stair/lane overlap. Candidate25 passed its general physical checks but exposed real composed stair obstruction, so it is not structural acceptance. Candidate24's sign-orientation rejection was a real production blocker, repaired at the sign producer. Earlier fixture query-area/slope-rest errors and an obsolete local-door-size assertion were synthetic test defects, not production failures.

Headed26 used Main.tscn through production generation/publication. It passed all 23 diagnostic checks, saved 29 captures, and exited naturally with no engine warnings/errors, no changed sources during the run, and zero owned processes. Every one of 3,253 source construction colliders matched published size/transform; no mismatches. All 36 live stair landing/exit capsule samples had support and clearance. This is live physics sampling, not a walked route.

## Visual observations and limits

Inspected all four house-entry captures: doors have readable proportions, nearby storage is off the approach, and incidental stalls are absent. urban_upper_lane.png shows connected paving/stairs. Keep landing/exit views show stairs, open wells and supports without the old full-width blocking pier. Gatehouse exit03 shows the upper connection and supported stairwell. Gatehouse exit00/01/02 cameras are occluded and cannot prove their visible routes; landing views show nearby walls/stair undersides and are not traversal proof. Courtyard overview shows the composed building arrangement. Furniture22/23 show wall-mounted decoration, not freestanding floating buildings. Dark, grainy interiors limit visual assessment even with clear daytime.

The test used two exterior setup teleports, ordinary W/Shift/jump approach, and diagnostic cameras. It did not walk all interiors, open residential doors, prove NPC routes, validate every decorative attachment, or establish general all-seed structural correctness. The final scene status was scene_ready with gameplayReady=false, reason door_activation_pending: this run must not be described as complete citadel gameplay acceptance. No NPC/navigation code was changed.

Runtime observation in headed report evidence.runtimePerformance: 419 retained samples, measured frame max 11.704ms, p95 8.142ms; section maxima include chunk 8.834ms, wildlife 6.068ms and autosave JSON/write 5.887ms. Scene publication max step was 29.308ms. The scene reached ready around 372 seconds. These limited instrumented samples and capture overhead do not establish performance acceptance or the worst wall-clock frame across the whole run. Long generation/publication and visual readability remain follow-up concerns.

