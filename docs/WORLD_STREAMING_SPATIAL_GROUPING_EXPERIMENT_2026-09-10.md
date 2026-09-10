# Spatial grouping experiment: not promoted

Branch: `codex/world-streaming-architecture`; reference: `f780e2c`.
This experiment does not satisfy the approved requirement that spatial culling
benefits outweigh additional submission cost. Production grouping is restored
to the reference. No competing renderer, feature switch or fallback is retained.

## Preserved experiment

`artifacts/citadel-runtime-integration/spatial-grouping-experiment.patch` records
the complete candidate against f780e2c, including its strict spatial audits and
contracts. The patch is archival evidence, not an enabled production path.
`spatial-grouping-comparison.json` in that directory contains the measured phases,
source identities and camera transforms from the matched runs.

The candidate assigned each source part one 43.2m XZ owner cell, including parts
crossing cell boundaries. Static visuals grouped by cell/material/unit-box family
with exact bounds and immutable instance-to-source spans. Source-complete cells
could flush while incomplete cells retained demand; remaining groups drained at
completion. The completion index was worker-prepared for runtime publication.
Physical part order, colliders, interactions and geometry were preserved.

The 12,000-instance group and 262,144-instance aggregate thresholds were checked
after a completed part. They were not strict memory ceilings: a large/resumable
part could exceed them. This was not complete memory backpressure or the planned
full packet identity, regional readiness, distance tiers or safe replacement.

## Matched headed measurement

Both runs used this command, with the respective fresh output directory:

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-spatial-02
```

Reference directory: `candidate-teleport-spatial-reference-01`. It used the four
f780e2c publication files with the corrected fixed-camera observer. Its audit
did not require spatial metadata absent from that reference. All other source,
collision and readiness checks remained. Source files were restored only after
the watchdog proved zero owned members, and verified against the retained source
snapshot. The candidate's strict audit was restored before its broad run.

Both headed runs passed all 27 diagnostic checks, made zero setup teleports,
exited naturally, had clean engine logs and proved zero owned members.
Each fixed view had 122 rendering samples over approximately two seconds.
All three camera transforms match exactly. Complete accepted source files share
SHA-256 `dbe543f28dfe876f28ae8611d7e869f07975f69e09067b2fe5c88d56e3e4b042`.
Both retain 241,573 instances and all 3,253 source colliders. Candidate ownership
audit: 1,486 groups, 211,105 static instances, 16 cells, zero coverage errors.

Values below are reference -> candidate; CPU/GPU are mean milliseconds. Draw
counts are phase maxima, with shadow submissions reported separately.

| View | Rendering CPU | Rendering GPU | Draws | Shadow draws |
|---|---:|---:|---:|---:|
| Overview | 3.475 -> 3.941 | 6.731 -> 6.529 | 2,449 -> 2,571 | 4,854 -> 5,128 |
| Courtyard | 3.152 -> 3.188 | 9.026 -> 8.481 | 1,990 -> 2,109 | 4,430 -> 4,685 |
| Home door | 1.047 -> 1.073 | 5.159 -> 5.331 | 665 -> 691 | 1,005 -> 1,048 |
| Input-driven exterior approach | 3.040 -> 2.970 | 5.858 -> 5.689 | 2,400 -> 2,526 | 4,158 -> 4,168 |

Total MultiMesh nodes increased from 1,548 to 1,679. Submitted main-view triangles
fell by approximately 3%, 1% and 20% at the respective fixed cameras. This did
not translate into a consistent timing improvement; approach cadence p99 stayed
17ms. Overview CPU p99 increased from 4.6ms to 6.8ms. The smaller triangle count
alone is insufficient to promote this grouping policy.

Candidate current startup readiness was 79.078s; full scene-ready was 128.928s.
Reference current startup readiness was 82.910s, with its ready capture at
132.429s. Single runs do not establish a cold-load speedup. The existing startup
contract is still not the required 64m dependency closure. Scene-ready is not
whole-site gameplay-ready: door activation remained pending in both reports.

Near home-door captures were compared side by side. Courtyard and gatehouse
landing captures were inspected. Geometry, openings and material character were
preserved; the poorly lit door and grainy surfaces are visible in both versions.
These observations do not prove interior interaction, NPC traversal, flag-free
menu New Game/Continue, five-minute pacing or full architecture acceptance.
Viewport CPU/GPU results are the last available engine timings, potentially
delayed; cadence is frame_post_draw timing, not OS presentation measurement.

## Verification and rejected iterations

Existing Node contract runners, all beneath `artifacts/citadel-runtime-integration`:

- `spatial-static-04`: BuildingStaticBatchFlushContract, 150 checks passed.
  Covers exact transforms/custom data/materials, negative and rotated owner cells,
  crossing bounds, partial-cell retention and parent-frame invalidation.
- `spatial-scene-job-05`: BuildingScenePublicationJobContract, 378 checks passed.
- `publication-worker-spatial-01`: existing worker contract, 62 checks passed.

All three final contract runs proved clean owned-process cleanup. These are
synthetic/service contracts, not live gameplay acceptance.

Earlier `candidate-teleport-spatial-01` added 410 MultiMeshes. Its spatial audit
incorrectly selected nodes by name (Godot renames duplicate node names), and its
fixed phases included subsequent camera moves. It is not accepted spatial
coverage or matched-camera evidence. The next run corrected both measurements
and coalesced retained cell groups before comparing against the reference.
Earlier scene-contract failures used a manually injected batch missing the new
owner/bounds fields and then the production collector's flush trigger. Those
were newly created synthetic-fixture failures; their final corrected contract
passed. No production safeguard was removed to resolve them.

Broad replay command, deliberately using the earlier failing baseline seed:

```text
node tools/run-playtest.mjs -Seed atlas-1492 -ReportPath artifacts/citadel-runtime-integration/spatial-broad-01/report.json -ProgressPath artifacts/citadel-runtime-integration/spatial-broad-01/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/spatial-broad-01/final.png -TimeoutSeconds 600
```

The candidate broad run stopped at `generated_prop_visuals`, after 123 recorded
checks (122 passed). `tutorial_npc_home_and_guard_behavior` failed, as it did in
the pre-packet baseline; it had passed the immediately preceding packet sample.
The new terminal failure is an engine RID initialization error in the headless
dummy renderer, including `mesh_set_blend_shape_mode` and `mesh_add_surface`.
This is not the known end-of-run screenshot failure. The Node watchdog stopped
the run on its engine-error guard: `artifacts/node-tools/process-runs/godot-ZXMzb8`.
It records forced cleanup, cleanupPassed=false and authoritativeZeroProven=true.
The report is incomplete and is not a broad pass. Asset-pack/screenshot checks
were not reached.

The same command with output paths under `spatial-broad-reference-01` replayed
f780e2c production after restoration. It finished 161/163, with only the known
`character_asset_pack_ready` and `screenshot_saved` failures. The NPC home/guard
check passed and the generated-prop RID error did not recur. Its end-of-run
headless screenshot error required forced cleanup; watchdog
`artifacts/node-tools/process-runs/godot-IJV5n1/watchdog.json` records
cleanupPassed=false and authoritativeZeroProven=true. This confirms the restored
production baseline outcome, not a clean broad pass. One replay does not prove
causality for the candidate RID error. It remains an additional unresolved
candidate failure; do not attribute it to baseline or reintroduce the candidate
without resolving it. No NPC routing code or acceptance check was changed.

## Next architectural work

Spatial subdivision must address submission overhead before being reintroduced.
Keep the retained source-owner experiment as evidence, not as justification to
enable a slower renderer. Material variation already creates distinct material
cache entries; a future batching change must preserve the first resolved values
and full per-instance appearance rather than merging by material name alone.

The candidate publication profile measured 13.125s cumulative job CPU. Nested
`masonry_authority_validation` accounted for 3.602s, including 3.339s in its
aperture guard; do not add these nested numbers. Unit-box source verification,
part/history binding and membership checks must be profiled or consolidated at
owned immutable boundaries, not skipped. Paving geometry was another 1.227s;
roof tile/custom-data stages were approximately 0.246s/0.228s. Static buffer
uploads totalled only 2.629ms. A 29.448ms publication operation still exceeded
the cooperative 4ms budget. More buffer-throughput tuning will not solve that.

Regional readiness owner inventory:

- `CitadelTerrainAdmission.request_bounds/request_source/source_state`: retained
  admission and source binding; not physical readiness.
- `VoxelTerrainRuntime`: chunk publication/republication/release and collision
  proof. Navigation notification after collision proof is not acknowledgement.
- `CitadelPublicationService.physical_publication_state`: currently gates an
  intersecting region on the entire site's scene-ready status.
- `BuildingScenePublicationJob`: sequential whole-site publication; no regional
  receipt for completed visuals, supports and crossings yet.
- `GeneratedStructureRuntimeBindings.register_door`: portal/leaf/smart-object
  registration receipts, not adjoining clearance or navigation proof. Preserve
  `construction_allowed`'s active-player capsule exclusion.
- `BuildingNavigationManifestBuilder`, `BuildingSiteManifestBuilder` and
  `BuildingNavigationTransitionCertifier`: authoritative surfaces/crossing
  semantics. Closure must include landings, supports, clearance and seam owners,
  including dependencies whose origins lie outside requested bounds.
- `GeneratedWorldNavigationAdapter` and `NavmeshWorldService`: tile source keys,
  installation/dirty state and synchronization observations. Current map-ready
  checks do not prove every required source revision and crossing is installed
  and synchronized. Add that publication receipt while preserving routing,
  movement, door execution and traffic.

The coordinator must retain each request's source binding, terrain chunks,
structural closure, door receipts and required navigation revisions. Compose
actual owner acknowledgements; never replace missing proof with metadata-ready.
