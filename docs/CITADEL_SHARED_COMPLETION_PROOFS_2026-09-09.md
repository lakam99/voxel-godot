# Share private support queries across completion proofs

The completion transaction now shares its existing BuildingSupportResolutionMemo
store with party-wall context creation and the bunting proposal's private proof.
Public recipe entry points remain fresh. Every proof still classifies and indexes
its own copied parts and performs full physical, root and dependency validation.
The bunting proof removes all declared dressing before it constructs the memo;
reuse depends on the resulting exact candidate/target bindings, not a claim that
all dressing is irrelevant.

Party-wall contexts seal their own report and proof, and detach the shared store
before returning. Bunting proposals expose neither store nor proof. Cancellation
and failure wrappers clear the shared store, including callbacks immediately
before/after validation and failures at the owning completion-stage boundary.
The memo implementation and its exact bindings/deep result copies are unchanged.
No observation hashes from the preceding investigation participate in reuse.

## Verification

```text
node tools/run-building-contract.mjs -Contract MasonryPartyWallProofReuseContract.gd -OutputDirectory artifacts/citadel-runtime-integration/shared-party-proof-01 -ReportEnvironment MASONRY_PARTY_WALL_PROOF_REUSE_REPORT -TimeoutSeconds 120
node tools/run-building-contract.mjs -Contract CitadelBuntingAnchorRecipeContract.gd -OutputDirectory artifacts/citadel-runtime-integration/shared-bunting-proof-01 -ReportEnvironment CITADEL_BUNTING_ANCHOR_REPORT -TimeoutSeconds 120
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-41 -Seed atlas-3376622889 -CandidateRegion "-2,-2" -ExpectedRecipeSeed 1393179273 -ExpectReady
node tools/run-citadel-candidate-integration-continuation.mjs -SourceDirectory artifacts/citadel-runtime-integration/candidate-recipe-41 -OutputDirectory artifacts/citadel-runtime-integration/candidate-continuation-41
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-41-01
node tools/run-playtest.mjs -ReportPath artifacts/citadel-runtime-integration/shared-proof-runtime-41/playtest-report.json -ProgressPath artifacts/citadel-runtime-integration/shared-proof-runtime-41/playtest-progress.txt
```

The existing party-wall and bunting contracts passed 72 and 99 checks respectively.
They cover complete cold/shared result parity, resolved snapshot parity for the
party-wall proof, actual memo hits with full validation retained, changed/missing
roots, dressing that cannot establish a mounting root, accepted changes, public
context tampering, detached stores and cancellation around the proof. These are
synthetic source contracts, not gameplay acceptance. Both exited cleanly with
owned-process zero.

Source41 preparation took 75.458s versus source39's 71.633s: this sample does not
show an overall offline speedup. Its accumulated support-resolution callback
intervals decreased from 17.110s to 16.075s. Independent physical validation took
2.384s. Callback intervals are wall observations, not exclusive CPU. The
source-diff-27-41 comparison found only civicClearance/elapsedUsec changed.
Continuation41 passed 26 checks. All gates exited cleanly with owned zero.

Headed41-01 passed 24 checks, with natural exit, clean logs and owned zero.
The first sampled scene-ready state was 157.130s (source39: 161.035s); ordinary
input approach began at 158.130s. The accepted source SHA remains
1f07667654652dbb53a4fb6107352d8fd1186ff79594b96563562f14ff5032f7, and all
3,253 declared colliders were published. ready.png was inspected and shows the
same citadel, terrain and conifer forest with the prior grainy-shadow appearance.
This is teleport-assisted publication evidence, not continuous traversal, NPC,
all-door or full visual acceptance. The separate gameplayReady limitation remains.
The 90-second usable-arrival target is still unmet.

The mandatory atlas-1492 broad run stopped at 97 passing checks, finished=false,
after dummy-renderer wrong/uninitialized RID, null mesh and renderer scene-cull
errors. It is incomplete, not a passing broad run. The watchdog at
artifacts/node-tools/process-runs/godot-SjrUjK/watchdog.json records forced cleanup,
cleanupPassed=false, authoritativeZeroProven=true and no final job members.

These error categories predate this change. The wrong/uninitialized RID and
mesh chain appears in artifacts/citadel-runtime-integration/biome-runtime-35/
baseline-stderr.log. The scene-cull error also appears in
artifacts/node-tools/process-runs/godot-ayKzKO/stderr.log (earlier broad launch,
2026-09-09T22:15:53.664Z) and native-admission-07/stderr.log under the integration
artifact directory. The latter launch records ancestor commit
8ec52667be7a84088064b74e2c90b2bf89a3589a, verified by git merge-base. This attributes
the known failure categories; it does not clear the renderer defect or replace
complete broad gameplay evidence.
