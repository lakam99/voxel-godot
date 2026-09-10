# Private party-wall failure-set reuse

CitadelStructuralCompletionRecipe now extracts a private list of failed part
IDs after validating its private party-wall proof. Declarations with no failed
members consume only that list, rather than repeatedly serializing the unchanged
derived proof and report. The context and copied IDs never escape the operation.
Every post-callback source guard remains. Actual repairs still validate the full
context before and after use; successful changes clear both context and IDs.
Public supplied-context behavior, physical validation and cancellation are unchanged.

## Evidence

Directories below are under artifacts/citadel-runtime-integration.
party-wall-cost-01 replays the no-repair stage on final source37, not its earlier
production-stage input. It measured 10.761s for the stage and 6.609s for sixteen
context validations: proof serialization 3.900s, report serialization 1.767s,
source serialization 0.851s (separately measured, not exclusive sums).
party-wall-cost-02 reduced the stage to 4.150s with byte-identical stage output,
no repairs and unchanged source. Both diagnostic runs closed cleanly with owned zero.

```text
node tools/run-building-contract.mjs -Contract MasonryPartyWallProofReuseContract.gd -OutputDirectory artifacts/citadel-runtime-integration/party-private-noop-01 -ReportEnvironment MASONRY_PARTY_WALL_PROOF_REUSE_REPORT -TimeoutSeconds 120
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-38 -Seed atlas-3376622889 -CandidateRegion "-2,-2" -ExpectedRecipeSeed 1393179273 -ExpectReady
node tools/run-citadel-candidate-integration-continuation.mjs -SourceDirectory artifacts/citadel-runtime-integration/candidate-recipe-38 -OutputDirectory artifacts/citadel-runtime-integration/candidate-continuation-38
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-38-01
```

The existing proof-reuse contract passed 62 checks, including mixed repairs and
no-ops, supplied-context mutations, callback source mutations and cancellation.
Source38 passed with 76.295s preparation versus source37's 84.524s, and 2.597s
independent physical validation. source-diff-27-38 found only civicClearance's
elapsedUsec observation changed. Continuation38 passed 26 checks. All had clean
owned-zero termination. The critic's conditional source/continuation/headed gates
were satisfied before each dependent launch.

The actual source stage had sixteen no-op declarations and no plan callbacks,
matching the profile's workload. Its party_wall_item intervals fell from 6.467s
to 0.589s. These callback intervals are wall observations, not exclusive CPU.

Headed38-01 passed 24 checks with clean natural exit and owned zero. Source was
accepted at 108.124s, scene construction began at 126.192s, and the first sampled
scene-ready state was 166.359s (previously 170.732s). The accepted source payload
SHA remains 1f07667654652dbb53a4fb6107352d8fd1186ff79594b96563562f14ff5032f7.
All 3253 declared colliders were published. Ready.png was inspected and shows the
citadel, terrain and trees consistently. This is teleport-assisted publication
evidence, not continuous approach, NPC behavior, door interaction or every visual
and collision detail. The separate gameplayReady limitation remains as documented.
The 90-second usable-arrival goal remains open.

Broad regression command:

```text
node tools/run-playtest.mjs -ReportPath artifacts/citadel-runtime-integration/party-runtime-38/playtest-report.json -ProgressPath artifacts/citadel-runtime-integration/party-runtime-38/playtest-progress.txt
```

The atlas-1492 baseline replay finished with 161/163 checks passing. The two
failures were character_asset_pack_ready (40 ready assets versus the existing
30-asset expectation) and screenshot_saved (null texture in the headless dummy
renderer). Both match the preceding occupancy-runtime-37 baseline. This is a
failed broad run, not clean gameplay or NPC acceptance.
artifacts/node-tools/process-runs/godot-1AXauK/watchdog.json records forced
cleanup, cleanupPassed=false, authoritativeZeroProven=true and no final job
members. The critic's scoped commit condition was satisfied: only the previously
attributed failures remained and owned-process zero was confirmed.
