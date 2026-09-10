# Reuse validated endpoint invariants during occupancy subtraction

ReplacementBoxOccupancy now validates inputs at its public boundary and uses
a private intersection operation within subtraction. All internal inputs start
validated; min/max intersections and strict interior splits preserve finite,
bounded, positive boxes. Public intersection still rejects invalid inputs.
Splitting order, work increments, work/cell limits and output encoding remain
unchanged. No geometry, tolerance, source acceptance or publication budget changed.

## Focused evidence

All directories below are under artifacts/citadel-runtime-integration.

```text
node tools/run-building-contract.mjs -Contract ReplacementBoxOccupancyContract.gd -OutputDirectory artifacts/citadel-runtime-integration/occupancy-validated-02 -ReportEnvironment VOXEL_REPLACEMENT_BOX_REPORT -TimeoutSeconds 120
node tools/run-building-contract.mjs -Contract OpeningHeadReplacementAdmissionContract.gd -OutputDirectory artifacts/citadel-runtime-integration/occupancy-admission-01 -ReportEnvironment VOXEL_HEAD_REPLACEMENT_ADMISSION_REPORT -TimeoutSeconds 120
node tools/run-building-contract.mjs -Contract res://artifacts/citadel-runtime-integration/support-local-observation-src/OccupancyDifferential.gd -OutputDirectory artifacts/citadel-runtime-integration/occupancy-differential-01 -ReportEnvironment OCCUPANCY_DIFF_REPORT -TimeoutSeconds 120
```

Occupancy passed 170 checks including invalid/nonfinite inputs, mixed integer
and float endpoints, signed zero, coordinate boundaries, precise work-limit
behavior and fragmentation rejection. Replacement admission passed 59 checks.
The artifact differential compared complete old/new cover, removed and intersection
results for 1200 deterministic cases, including exact work counters: all equal.
Old measured work was 394081us versus 147275us. All runs closed cleanly with owned zero.

The existing historical OpeningHead replay (synthetic empty furniture policy)
fell from 8.584s to 7.269s; instrumented replacement admission fell from 4.071s
to 2.807s. Evidence: support-local-observation-02 and -03. This is component
timing, not a live speedup. Both branches of run03 use current occupancy; its
result equality proves observer transparency, while old/new algebra parity
comes from the separate differential above.

## Full candidate and headed result

```text
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-37 -Seed atlas-3376622889 -CandidateRegion "-2,-2" -ExpectedRecipeSeed 1393179273 -ExpectReady
node tools/run-citadel-candidate-integration-continuation.mjs -SourceDirectory artifacts/citadel-runtime-integration/candidate-recipe-37 -OutputDirectory artifacts/citadel-runtime-integration/candidate-continuation-37
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-37-01
```

Source37 passed: preparation 84.524s, independent physical validation 2.708s,
total 87.860s. Source36 preparation was 88.363s. source-diff-27-37 found only
the civicClearance elapsedUsec observation differing; continuation37 passed
26 checks. Critic source PASS and conditional headed GO preceded the run.

Headed37-01 passed 24 checks, clean logs, natural exit and owned zero. Source
acceptance was 112.570s, scene publication 129.630s, scene-ready 170.732s.
This is effectively unchanged from 170.539s in 36-05; no live arrival speedup
is claimed. The accepted-source.bin SHA is still
1f07667654652dbb53a4fb6107352d8fd1186ff79594b96563562f14ff5032f7.
Ready.png was inspected and shows the same citadel, terrain and trees.
Teleport-assisted publication does not prove continuous traversal, every
collision/visual detail, NPC behavior or door interaction. The 90s usable-arrival
goal remains unmet despite the lower component computation cost.

The required broad regression completed on baseline seed atlas-1492:

```text
node tools/run-playtest.mjs -ReportPath artifacts/citadel-runtime-integration/occupancy-runtime-37/playtest-report.json -ProgressPath artifacts/citadel-runtime-integration/occupancy-runtime-37/playtest-progress.txt
```

161/163 checks passed. The known character_asset_pack_ready exact-count mismatch
and headless screenshot_saved failure remain. The tutorial NPC check passed on
this run; no NPC fix or regression conclusion follows from that timing-dependent
variation. The same null-texture error during screenshot capture caused owned
termination. artifacts/node-tools/process-runs/godot-fV9EG3/watchdog.json proves
owned zero, but cleanupPassed is false. This is not a clean broad-suite pass.
The critic's scoped commit approval required no new failure category and owned
zero; both conditions were met. No extra normal-runtime pass was performed:
this change affects source algebra, while the full candidate, headed publication
and broad regression exercised the applicable changed path.
