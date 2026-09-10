# Reuse exact-X support filtering within physical validation

BuildingBlueprint now factors its exact-XZ support shortlist into an exact-X
shortlist per grid origin, followed by the existing Z predicate. The neighbor
list and order are identical within each origin; rotated candidates remain in
both filters. Vector3 subtraction retains the former boundary rounding.
This changes no support selection, geometry, collision, root proof or navigation.

The new cache mirrors all four existing column-cache invalidation sites:
resolution entry, cancellation, indexing, and owner exit. It survives only the
current synchronous validation ownership.
The critic caught missing nested-cancellation cleanup in the initial artifact
prototype; the production implementation and contracts cover it.

## Measurement and verification

All evidence directories below are under artifacts/citadel-runtime-integration.
The pinned final source38 SHA is
190e1f310f61eadc2d372a76a743dc6ddf4bcf0defda6120c4e91c943e2df8ea.
physical-cost-01 measured 1.873s support resolution within a 2.501s physical proof.
physical-cost-02 attributed 1.004s to column filtering. Nested observer timings
include instrumentation and are not exclusive production CPU measurements.
physical-column-cost-01 compared the unchanged implementation to an isolated
candidate: 2.482s versus 2.085s, with exact report and resolved-snapshot bytes.
physical-cost-03 compared production to the frozen pre-change implementation:
both complete outputs remained exact, and instrumented column filtering took
0.531s. The final replay retained 14,959 X shortlists and 248,691 references at
peak, then cleared them at owner exit. These are offline proof measurements.

```text
node tools/run-building-contract.mjs -Contract BuildingValidationCacheContract.gd -OutputDirectory artifacts/citadel-runtime-integration/column-cache-01 -ReportEnvironment VOXEL_BUILDING_VALIDATION_CACHE_REPORT -TimeoutSeconds 120
node tools/run-building-validation-cancellation-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/column-cancellation-02 -AuthorizeLaunch
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-39 -Seed atlas-3376622889 -CandidateRegion "-2,-2" -ExpectedRecipeSeed 1393179273 -ExpectReady
node tools/run-citadel-candidate-integration-continuation.mjs -SourceDirectory artifacts/citadel-runtime-integration/candidate-recipe-39 -OutputDirectory artifacts/citadel-runtime-integration/candidate-continuation-39
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-39-01
node tools/run-playtest.mjs -ReportPath artifacts/citadel-runtime-integration/column-runtime-39/playtest-report.json -ProgressPath artifacts/citadel-runtime-integration/column-runtime-39/playtest-progress.txt
```

Cache contract: 88 checks. Cancellation contract: 465 checks. Both clean with
owned-process zero. Controls include ordered membership, large/negative
coordinates, exact contact boundaries, rotations, reindex after movement/removal,
repeated validation, nested cancellation and fresh direct queries. The earlier
column-cancellation-01 attempt used the generic runner without the required stage
map and failed JSON setup; it is not evidence of a production defect.

Source39 preparation took 71.633s (source38: 76.295s), with 2.109s independent
physical validation. Accumulated source support callback intervals fell from
20.610s to 17.110s; these are wall intervals, not exclusive CPU. source-diff-27-39
found only civicClearance/elapsedUsec changed. Continuation passed 26 checks.
All terminated cleanly with owned zero. The critic's sequential gates were met.

Headed39-01 passed 24 checks and exited naturally with clean logs and owned zero.
Source accepted at 102.732s, scene publication observed at 118.770s, and first
sampled scene-ready at 161.035s, versus 166.359s previously. The accepted source
SHA remains 1f07667654652dbb53a4fb6107352d8fd1186ff79594b96563562f14ff5032f7.
All 3,253 declared colliders were published. ready.png was inspected: the citadel,
terrain and conifer forest remain visible, with the prior grainy shadow appearance.
This is teleport-assisted publication evidence, not continuous traversal, NPC,
all-door or complete visual acceptance. gameplayReady remains false with
door_activation_pending. The 90-second usable-arrival goal remains unmet.

The atlas-1492 broad replay finished 160/163, with the recorded baseline failures
tutorial_npc_home_and_guard_behavior, character_asset_pack_ready (40 ready assets
versus the existing 30 expectation), and screenshot_saved (headless null texture).
This is a failed broad run, not clean gameplay acceptance.
artifacts/node-tools/process-runs/godot-azIsYm/watchdog.json records forced cleanup,
cleanupPassed=false, authoritativeZeroProven=true and zero final job members.
This satisfies the critic's scoped conditional commit approval; it does not
waive the broader gameplay failures or the remaining load-time goal.
