# Worker-owned publication record revisions

Phase 2 continuation on `codex/world-streaming-architecture`, after c6cd2de.
This advances immutable source ownership; it does not complete spatial grouping,
regional readiness, rendering tiers or the 90-second/60-FPS acceptance contract.

## Change and authority

`BuildingPart` now tracks writes to all ten serialized fields after its compiler
seals it for publication. Sealing accepts an isolated, deeply frozen recipe.
Scalar changes and recipe replacement advance the revision; restoring a prior
value does not revive the old receipt. Nested recipes cannot mutate underneath
an in-flight packet. Recompilation restores a fresh mutable source snapshot.

`BuildingPublicationPreparation.prepare_source` seals only the fresh masonry
records that it restored and exclusively owns on its worker, after physical
resolution and geometry preparation. Each immutable prepared entry retains the
exact source object, its revision and its frozen recipe identity. Validation
checks those identities, the exact BuildingPart implementation and the existing
history certificate instead of repeatedly copying/serializing the entire recipe.

The authoring blueprint, admission snapshot and durable state are not frozen or
rewritten. Direct generic `_compile_masonry` callers retain their existing mutable
input contract and exact serialization checks. No second geometry authority or
silent runtime renderer fallback was introduced. Save snapshots omit internal
publication revisions and retain format v2. These internal receipts defend the
owned lifecycle, not deliberate tampering with private fields.

Post-compilation authoring/physical resolution must use mutable snapshot copies.
The inspected runtime publication consumers read these records; physical
resolution completes before sealing. Geometry algorithms, materials, batching,
collision, door execution, navigation and readiness semantics are unchanged.

## Focused verification

All paths below are under `artifacts/citadel-runtime-integration`.

```text
node tools/run-building-contract.mjs -Contract BuildingPreparedMasonryContract.gd -ReportEnvironment BUILDING_PREPARED_MASONRY_OUTPUT -OutputDirectory artifacts/citadel-runtime-integration/owned-records-masonry-05 -TimeoutSeconds 120
node tools/run-building-contract.mjs -Contract BuildingScenePublicationJobContract.gd -ReportEnvironment BUILDING_SCENE_PUBLICATION_JOB_OUTPUT -OutputIsDirectory -OutputDirectory artifacts/citadel-runtime-integration/owned-records-scene-01 -TimeoutSeconds 120
node tools/run-building-publication-worker-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/publication-worker-owned-records-01
```

Results: 223, 378 and 62 checks respectively; clean engine logs and clean owned
process retirement. New synthetic controls exercise the actual prepare_source
path, exact resolved-source bytes, unchanged mutable authoring inputs, recursive
recipe immutability, all ten field changes, recipe replacement, non-revival after
restoration and one-shot holder consumption. Existing descriptor/material and
lifecycle checks remain. These are contract/service evidence, not gameplay proof.

An initial parse check caught a missing setter declaration colon. The subsequent
new fixture comparison exposed unfinished physical-intent provenance: first
resolution wrote `building_part_taxonomy`, whereas repeated resolution wrote
`recipe`. The fixture now declares structural intent before resolution, as an
accepted production input does. Its exact-byte check remains. These setup
failures were not production geometry failures; no acceptance guard was removed.

## Headed production diagnostic

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-owned-records-01
```

All 27 checks passed. Zero setup placements, natural exit, clean engine logs,
cleanupPassed=true and authoritativeZeroProven=true. This uses Main's ordinary
production systems with initial spawn selected before player/terrain attachment.
The fixture bypasses the menu and applies explicit scenario/lighting flags.

Complete accepted source SHA-256 is unchanged from the committed reference:
`dbe543f28dfe876f28ae8611d7e869f07975f69e09067b2fe5c88d56e3e4b042`.
All 241,573 instances, 1,548 MultiMeshes and 3,253 source colliders are preserved.
Inspected ready exterior, courtyard and gatehouse stair-landing captures. The
citadel, nearby terrain and foliage remain visible; existing grainy materials
and poorly lit enclosed views remain. No geometry or detail was removed.

Comparison against `candidate-teleport-spatial-reference-01` (f780e2c production):

| Measurement | Reference | Owned records |
|---|---:|---:|
| Current startup readiness | 82.910s | 82.543s |
| Scene-ready capture | 132.429s | 127.030s |
| Cumulative scene publication CPU | 12.792s | 11.738s |
| Prepared masonry lookup total | 637.145ms | 14.683ms |
| Masonry geometry-begin total | 1,111.413ms | 31.768ms |
| Worker masonry preparation | 6.594s | 6.838s |
| Largest scene publication operation | 27.592ms | 28.445ms |

Lookup is nested inside geometry-begin; do not add these savings. The result is
one comparison, not statistical cold-load acceptance. The remaining nested
aperture guard increased from 3.175s to 3.840s in this sample; no reduction in
that safeguard's cost is claimed. It still checks native unit arrays, source
membership, declared apertures and associated peer geometry.

Ordinary exterior approach: cadence p99 17.1ms, maximum 32.299ms, no samples over
33ms; rendering CPU/GPU p99 4.8/6.6ms. Publication cadence p99 29.8ms, maximum
76.358ms, 17 samples over 33ms. Overall observation has a 3.070s maximum and
includes startup and diagnostic capture/audit work. Engine cadence is not OS
presentation timing, and last-available viewport GPU values may be delayed.

The current startup gate is still not the required 64m dependency closure.
Scene-ready remains distinct from gameplay-ready (`door_activation_pending`).
This does not certify flag-free menu New Game/Continue, interior/NPC traversal,
five-minute 1080p pacing, required cold-run repetitions or full-site readiness.

## Broad and NPC regression

Mandatory broad replay of the known baseline seed:

```text
node tools/run-playtest.mjs -Seed atlas-1492 -ReportPath artifacts/citadel-runtime-integration/owned-records-broad-01/report.json -ProgressPath artifacts/citadel-runtime-integration/owned-records-broad-01/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/owned-records-broad-01/final.png -TimeoutSeconds 600
```

Finished 160/163. Failures: `tutorial_npc_home_and_guard_behavior`,
`character_asset_pack_ready` (40 assets/11 families) and `screenshot_saved`.
These are the three recorded pre-packet baseline failures; the NPC assertion
passed the intervening packet/reference samples but failed again here. It is
not dismissed as a clean pass or used as evidence of live NPC correctness.
The first two remain functional coverage gaps. The headless renderer cannot
provide the requested screenshot; its existing null-texture error required
watchdog cleanup. `artifacts/node-tools/process-runs/godot-FRHSBv/watchdog.json`
records forcedCleanup=true, cleanupPassed=false and authoritativeZeroProven=true.
The earlier rejected spatial experiment's RID initialization error did not recur.
All thirteen local contract/headed watchdog records for this milestone also
prove zero owned members; the separate generic NPC watchdog is clean.

Generic NPC contract replay passed all 84 checks, with clean natural exit and
ownedZero in `artifacts/node-tools/process-runs/godot-SRZDRU/watchdog.json`:

```text
node tools/npc/run-npc-contract-tests.mjs -TimeMode Both -ReportPath artifacts/citadel-runtime-integration/owned-records-npc-contract-01/report.json -ProgressPath artifacts/citadel-runtime-integration/owned-records-npc-contract-01/progress.txt -TraceDir artifacts/citadel-runtime-integration/owned-records-npc-contract-01/traces -ScreenshotDir artifacts/citadel-runtime-integration/owned-records-npc-contract-01/captures
```

This is generic contract evidence, not live NPC route acceptance. Previously
recorded detached-fixture navigation/streaming-save failures remain attributed
in WORLD_STREAMING_PACKETS_AND_INITIAL_SPAWN_2026-09-10.md. No protected route
code changed in this milestone.
