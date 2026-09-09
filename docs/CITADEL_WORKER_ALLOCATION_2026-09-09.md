# Terrain worker allocation and citadel arrival

The native voxel worker ratio changes from the engine default 0.5 to 0.25.
On this 16-logical-processor host this means eight to four workers; it is not
a four-worker cap on every machine. Geometry, deterministic generation,
readiness checks, navigation and publication slice budgets are unchanged.

The existing teleport runner now records VoxelEngine.get_stats once per existing
one-second progress tick, retaining at most 720 samples plus an overflow count.
These are instantaneous task gauges, unlike summed performance counters.
CitadelWorkerEnvironment.gd records the installed engine configuration only.
worker-environment-02 and -04 confirmed eight and four workers respectively,
both with clean owned-zero termination. Installed voxel revision:
595f52ee4e23203a865eeb981f115909f7aa92f4.

## Same-source headed comparison

Both runs used:

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-36-03
```

The four-worker run used fresh output candidate-teleport-36-04. All evidence
directories below are under artifacts/citadel-runtime-integration unless stated.

| Observation | Eight workers, 36-03 | Four workers, 36-04 |
| --- | ---: | ---: |
| Startup to source discovery | 18.207s | 18.136s |
| Source accepted | 134.424s | 113.249s |
| Publication starts building scene | 187.558s | 130.301s |
| First sampled scene-ready state | 250.717s | 193.418s |
| Route geometry preparation | 22.023s | 5.025s |
| Physical preparation | 14.492s | 3.942s |
| Metadata preparation | 3.293s | 1.409s |
| Scene publication CPU | 11.388s | 11.295s |
| Between publication advances | 50.955s | 51.771s |

Eight native GenerateBlock tasks overlapped the slow preparation phase in 36-03.
The four-worker run improved total arrival by about 57 seconds. This establishes
an allocation-policy improvement on this host, not exclusive CPU/lock attribution.
Between-advance time includes other frame work and rendering, not just idle time.

Both runs passed all 24 diagnostic checks, natural exit, empty engine-error
inventory and clean owned zero. Both published 3253/3253 declared colliders.
Their entire accepted-source.bin payloads have the same SHA-256 as 36-02:
1f07667654652dbb53a4fb6107352d8fd1186ff79594b96563562f14ff5032f7.
That payload was previously proved byte-identical to the source36 blueprint and
furnishing input by runtime-source-diff-36.

Inspected ready.png in both runs, plus urban_row_03_right_door.png and
castle_keep_stair_exit_01.png in 36-04. Citadel, terrain and trees are visible;
the sampled doorway has no stall obstruction and the sampled stairs have a
landing. Dark/grainy rendering remains. These captures are not proof of every
structure, live door interaction, continuous traversal or NPC acceptance.
The job's separate gameplayReady remains false; scene_ready is not equivalent
to complete gameplay acceptance. The 90-second arrival target remains unmet.

## Broader regression evidence and limits

```text
node tools/run-playtest.mjs -ReportPath artifacts/citadel-runtime-integration/worker-allocation-04/playtest-report.json -ProgressPath artifacts/citadel-runtime-integration/worker-allocation-04/playtest-progress.txt
node tools/run-normal-runtime-performance-pass.mjs -ReportPath artifacts/citadel-runtime-integration/worker-allocation-04/normal-runtime.json -ProgressPath artifacts/citadel-runtime-integration/worker-allocation-04/normal-runtime-progress.txt -TimeoutSeconds 300
```

The broad test replayed baseline seed atlas-1492. It completed 163 checks: 160
passed; tutorial_npc_home_and_guard_behavior, character_asset_pack_ready and
screenshot_saved failed. The tutorial failure was already recorded. The asset
assertion demands exactly 30 assets, while ready registries report 40 and 11
families; it is not evidence of missing assets. Headless screenshot capture
raised null-texture ERROR, so the watchdog stopped the process. This is a new
observed renderer failure location, not the earlier RID failure replay.
Receipt: artifacts/node-tools/process-runs/godot-Pl7zbo/watchdog.json;
owned zero true, cleanupPassed false. The broad suite is not a pass.

Normal runtime used ordinary main-menu New Game and fresh seed atlas-35635264.
The 75-second sprint traversal result passed its performance/collision checks:
35.023s startup, 724.717m accumulated travel, 98.291m displacement, 4081 collision
samples, maximum below-collision distance 0.063m, p95 13.281ms, p99 15.591ms,
maximum 22.349ms. These measured timings do not cover all loading/render work,
all seeds or other hardware. It then repeated the previously observed exit
ObjectDB warning and seven-resources-in-use error. The watchdog stopped it;
receipt artifacts/node-tools/process-runs/godot-8cnISx/watchdog.json proves owned
zero but cleanupPassed false. This is a passing measured traversal with failed
shutdown, not a clean end-to-end acceptance run. No NPC code or tests were changed.

Next investigate the remaining source construction and scene-publication delays,
preserving retryable work, physical validation and nearby collision readiness.
