# Citadel publication slice

StructureSystem now explicitly requests the existing supported 4000us shared
citadel publication slice, replacing its implicit 2500us default. Service/job
defaults, 4000us maximum, fairness, cancellation, construction guards, physics,
source admission and navigation are unchanged. This is a cooperative slice;
an indivisible operation can exceed it. Four native workers remain configured.

## Verification

Evidence directories are under artifacts/citadel-runtime-integration.

```text
node tools/run-citadel-publication-service-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/publication-service-4ms
node tools/run-building-contract.mjs -Contract BuildingScenePublicationJobContract.gd -OutputDirectory artifacts/citadel-runtime-integration/scene-job-4ms -ReportEnvironment BUILDING_SCENE_PUBLICATION_JOB_OUTPUT -OutputIsDirectory -TimeoutSeconds 120
node tools/run-building-scene-publication-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-4ms
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-36-05
```

Focused suites passed 69, 376 and 70 checks respectively, all clean owned zero.
They cover service lifecycle, bounded job behavior and actual scene publication,
not normal gameplay. The critic approved the isolated change and headed run
after these gates. Headed36-05 passed 24 checks, natural exit and clean owned zero.

| Observation | 2500us, 36-04 | 4000us, 36-05 |
| --- | ---: | ---: |
| Source accepted | 113.249s | 111.372s |
| Scene publication begins | 130.301s | 128.411s |
| First sampled scene ready | 193.418s | 170.539s |
| Scene interval | 63.117s | 42.128s |
| Publication advance calls | 3924 | 2741 |
| Publication CPU | 11.295s | 11.442s |
| Between-advance time | 51.771s | 30.516s |
| Maximum atomic publication operation | 26.620ms | 27.889ms |

Ready.png was captured at 171.263s and inspected: terrain, trees and the citadel
are visible, consistent with the previous view. The complete accepted-source.bin
SHA remains 1f07667654652dbb53a4fb6107352d8fd1186ff79594b96563562f14ff5032f7;
3253/3253 declared colliders were published. No generated content changed.
The retained final performance window max was 8.604ms, p95 6.732ms and p99
7.991ms, versus 8.441/6.623/7.549ms previously. This window is not whole-run
frame acceptance, and between-advance time includes other frame/render work.

This is teleport-assisted publication evidence, not continuous approach, NPC
acceptance, door operation or proof of all visual/structural details. The separate
gameplayReady flag remains false as previously documented. The 90-second usable
arrival target remains open. The largest remaining cost is source preparation.

The required broad regression was rerun with baseline seed atlas-1492:

```text
node tools/run-playtest.mjs -ReportPath artifacts/citadel-runtime-integration/publication-budget-4ms/playtest-report.json -ProgressPath artifacts/citadel-runtime-integration/publication-budget-4ms/playtest-progress.txt
```

It completed 163 checks, 160 passing, with the same three failures as the
immediately preceding 2500us run: tutorial_npc_home_and_guard_behavior,
character_asset_pack_ready (exactly 30 expected, 40 ready assets available),
and screenshot_saved. The same headless null-texture screenshot error triggered
owned termination. The watchdog at
artifacts/node-tools/process-runs/godot-9B0uyC/watchdog.json proves owned zero;
cleanupPassed is false. This remains a failed broad suite, not gameplay acceptance.
No additional ordinary-runtime run was made for this citadel-only caller change;
the preceding measured traversal and its failed shutdown are documented in
CITADEL_WORKER_ALLOCATION_2026-09-09.md. Read-only critic approval was conditional
on this unchanged broad failure set and owned-zero evidence, both satisfied.

## Rejected experiment

Before this change, snapshot-encoding-01 compared direct synchronous encoding
against deep-copy-then-encode on source36. All 18 encoding checks passed, but
12 full encodings improved only from 354997us to 286371us. The small expected
saving did not justify a shared API; its production and fixture changes were
removed. The artifact remains diagnostic evidence, not a retained implementation.
