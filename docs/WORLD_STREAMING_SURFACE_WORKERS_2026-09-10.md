# Worker-prepared paving and roofs

Branch: codex/world-streaming-architecture, following bc0f6d7.

The existing preparation worker now compiles ordinary unjointed paving and roof
geometry plus immutable 256-instance upload segments. Roof arithmetic was moved
into BuildingRoofGeometry; diagnostic publication uses that same cursor. Material
hooks and source order remain on the main thread. The existing publication job,
collision, interaction and retirement owners are preserved. Prepared sources are
sealed and revision-bound, as for masonry. No save or generation algorithm changed.

Paving stones now enter the shared static batches instead of separate per-part
MultiMeshes. This changes flush boundaries/group counts, not geometry or identity.
Jointed paving continues through its authoritative cut-geometry publication path.

## Focused verification

All commands use node tools/run-building-contract.mjs with -TimeoutSeconds 120.
Artifacts below are under artifacts/citadel-runtime-integration.

- BuildingPreparedMasonryContract.gd, BUILDING_PREPARED_MASONRY_OUTPUT,
  surface-worker-compiler-03: 253 checks, clean logs/exit and ownedZero. Includes
  both new families' exact geometry, frozen packets, bounded segments, source
  revisions, replacement rejection and cancellation across compilation stages.
- BuildingRoofPublicationContract.gd, BUILDING_ROOF_PUBLICATION_OUTPUT,
  surface-worker-roof-01: 266 checks, clean logs/exit and ownedZero. Compares with
  the frozen original roof oracle, including compatibility hooks, prepared
  publication, cancellation, lost owners and off-thread resource retirement.
- BuildingScenePublicationJobContract.gd, BUILDING_SCENE_PUBLICATION_JOB_OUTPUT,
  surface-worker-scene-02: 378 checks, zero failures, clean engine logs/exit and
  ownedZero. The invocation omitted -OutputIsDirectory: its completed report is
  report.json/report.json and the wrapper then reported EISDIR. This is a wrapper
  invocation error, not a successful wrapper run. Use -OutputIsDirectory next time.

Initial compiler attempts exposed a nested-class resolution error and an empty
typed-array error; both were fixed before headed launch. The first scene attempt
also caught a new observer comparing cancellation state changes as submissions;
the observer now compares work counters, retaining the no-submission assertion.
These failures were not attributed to the production baseline.

## Headed production diagnostic

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-surface-worker-01
```

Passed, natural exit, clean logs and ownedZero. Zero setup teleports. Source SHA256
dbe543f28dfe876f28ae8611d7e869f07975f69e09067b2fe5c88d56e3e4b042 matches the reference.
241573 instances and 3253 source colliders retained. MultiMeshes fall from 1548 to
1477 because paving joins the shared batches; no spatial subdivision is enabled.
Inspected initial terrain, courtyard and gatehouse landing captures. Roof/paving
detail remains present; existing grainy materials and enclosed lighting persist.

Compared with candidate-teleport-owned-records-01:

| Measurement | Previous | Candidate |
|---|---:|---:|
| Current startup gate | 82.543s | 80.048s |
| Scene-ready capture | 127.030s | 122.318s |
| Publication CPU | 11.738s | 11.539s |
| Largest publication operation | 28.445ms | 26.760ms |
| Paving geometry on main | 1206ms | absent; 3.3ms prepared lookup |
| Worker paving / roof preparation | absent | 1385ms / 642ms |
| Aperture guard cumulative cost | 3840ms | 5778ms |
| Publication cadence p99 / max | 29.8 / 76.4ms | 30.4 / 77.1ms |
| Publication samples above 33ms | 17 | 10 |
| Exterior approach cadence p99 / max | 17.1 / 32.3ms | 17.0 / 28.3ms |

This is one sample, not proof of statistically faster cold loading. CPU savings
are offset by remaining aperture validation. Retained static memory at the fixed
cameras increased by roughly 42MB. Rendering CPU is lower at these cameras while
GPU time is slightly higher; no general GPU improvement is claimed. Cooperative
publication still exceeds 4ms. No limit or safeguard was relaxed.

Scene-ready is still not gameplay-ready (door_activation_pending). This does not
prove the 64m regional contract, ordinary menu Continue, interior NPC traversal,
five-minute performance or cold-run repetitions. Full-site completion stays separate.

## Broad regression

```text
node tools/run-playtest.mjs -Seed atlas-1492 -ReportPath artifacts/citadel-runtime-integration/surface-worker-broad-01/report.json -ProgressPath artifacts/citadel-runtime-integration/surface-worker-broad-01/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/surface-worker-broad-01/final.png -TimeoutSeconds 600
```

Finished 161/163. Recorded baseline failures: character_asset_pack_ready (40 assets,
11 families) and screenshot_saved. Tutorial home/guard check passes in this sample.
Headless screenshot capture emits the existing null-texture error. Watchdog
artifacts/node-tools/process-runs/godot-HX7O18/watchdog.json records forced cleanup,
cleanupPassed=false and authoritativeZeroProven=true. No RID initialization error.
This is not a clean broad pass or live NPC acceptance. Geometry/navigation inputs
and the protected route stack were not changed by this milestone.

## Next architectural work

Regional demand must compose actual physical, interaction and navigation receipts.
Current published tile-key caches and coarse map readiness do not prove exact
revision installation/synchronization. Add those receipts at the publication owner,
preserving route search/movement/door execution. Source dependency closure must
precede partial site readiness; render grouping need not coincide with source ownership.

The user raised New Game versus Continue timing on 2026-09-10. Keep those separate:
fresh process with empty generated caches; Continue with reusable artifacts; and
new-territory traversal. The cold 90s target is provisional pending evidence and a
replacement decision, not silently changed to a larger number. Persistent disposable
artifact caching may speed Continue while durable save format remains v2.
