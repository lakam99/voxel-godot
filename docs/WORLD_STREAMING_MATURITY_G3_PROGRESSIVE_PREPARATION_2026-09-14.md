# World Streaming Maturity Gate 3 — Progressive Preparation

Date: 2026-09-14  
Branch: `codex/world-streaming-maturity-migration`  
Implemented from: `b38d897022b4f55fb6cb87d004f2d52a34dfc646`  
Gate result: **COMPLETE; GATE 4 VISUAL/RESOURCE/RETIREMENT WORK IS NEXT**

## Outcome

Gate 3 replaces repeated whole-Citadel foreground planning with one timing-free immutable publication plan, bounded spatial selection, exact dependency closure, and locality-sealed scene packets. Preparation now begins far enough ahead of a representative sprint to publish the first useful gate/courtyard/home window without modal loading, and later packet work continues after the first scene-ready transition until current demand drains.

The fixed-seed headed run used ordinary player input for 1,528.259 m of measured traversal (295.595 m source discovery, 1,005.990 m pre-publication travel, and 226.674 m close approach). All three movement phases recorded zero modal-loading frames. This directly addresses the earlier stationary-test limitation: the fixture presses ordinary movement/sprint/look/jump/strafe inputs and does not write the player transform or call a publication completion helper during the act phase.

No native kernel was implemented. Gate 2 selected none, and the corrected Gate 3 profile shows that removing repeated work and keeping scene mutation sliced is sufficient for this gate. Native raster/navigation work remains rejected by the exact Citadel findings already recorded in Gate 2.

## Production changes

- `CitadelPublicationPlan` builds a canonical, timing-free plan on the preparation worker. It owns stable group records, semantic first-useful targets, exact physical dependencies, dependency closures, member/spatial buckets, and a typed SHA-256 signature that excludes measured timings.
- View demand queries traverse bounded near-to-far spatial buckets and rank at most 16 candidate rows per view before dependency expansion. Rear/side/reversal demand uses the same view-owned policy rather than an authored gate-only city version.
- Scene publication uses locality-sealed packets. Groups sharing a world partition publish together; door groups remain independently owned. Later hidden work cannot invalidate an already accepted support/aperture packet.
- Ahead-of-player preparation uses measured sprint speed, the existing view reach, and reversal margin. Speculative preparation does not start the source-demand clock or construct a scene; reversal can retire it while a matching completed base remains reusable.
- Silhouette, gate, visible courtyard, accessible home, current demanded closure, and full-source completion have separate timestamps. Courtyard targets are derived from actual courtyard paving/foundation semantics.
- The first scene-ready packet no longer strands later rolling packets. Scene-ready residents remain eligible for bounded publication advances until retained demand is complete.
- Navigation supplements use exact plan closure and a bounded 128-group rolling foreground. Regional navigation scheduling receives foreground priority without changing the protected route authority.
- Terrain durable save deltas now maintain an incremental canonical index and provide a compact immutable snapshot to autosave.

## Fixed-seed headed evidence

Command:

```powershell
node tools/run-citadel-candidate-teleport-playtest.mjs --OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-g3-ahead-12 --Seed atlas-3376622889 --CandidateRegion=-2,-2 --TimeoutSeconds 600 --StartupTimeoutSeconds 180 --SkipTutorial --ForceDaytime --ForceClearWeather --Resolution 1920x1080 --SpawnCell=-3334,-1629
```

Report: `artifacts/citadel-runtime-integration/candidate-teleport-g3-ahead-12/report.json`  
Watchdog: `artifacts/citadel-runtime-integration/candidate-teleport-g3-ahead-12/watchdog.json`

Result: PASS, functional exit 0, empty stderr, authoritative owned-process membership zero, and clean watchdog cleanup.

| Measurement | Result | Gate 2 goal |
|---|---:|---:|
| Prefetch lead before actual source demand | 213.722 s | stay ahead of representative travel |
| Scene start after source demand | 4.136 s | bounded progressive start |
| First stable silhouette | 5.267 s | ≤8 s |
| Usable gate/approach packet | 5.267 s | ≤16 s |
| Visible courtyard packet | 5.267 s | ≤20 s |
| Accessible furnished home packet | 5.267 s | ≤30 s |
| Complete current demanded closure | 13.718 s | ≤45 s |
| Physical groups published at final observation | 344 / 4,098 | progressive; full source remains deferred |
| Deferred hidden groups | 3,753 | bounded retained background work |
| Candidate rows per view | 16 max | ≤512 |
| View-window query p99/max | 1.021 / 1.021 ms | within demand envelope |
| Inclusive demand plan p99/max | 1.562 / 1.562 ms | max ≤2 ms; p99 is 0.062 ms above the 1.5 ms goal |
| Scene job advance p99/max | 2.878 / 3.014 ms | ≤4 ms |
| Autosave snapshot max | 0.270 ms | ≤2 ms |
| Terrain delta snapshot max | 0.010 ms | ≤1 ms |

The inclusive demand-plan p99 is one 1.562 ms observation among 94 expensive calls. The immediately preceding equivalent moving run measured 1.188 ms p99/max. The 0.062 ms miss is reported rather than hidden or used to raise the budget; it is below the plan's explicit sub-0.1 ms threshold-noise floor. The deterministic candidate cap, view-query result, max bound, sustained drain, and scene-job budget all pass. Final presentation acceptance remains Gate 5 work.

The headed report is a diagnostic initial-location New Game fixture and truthfully does not prove continuous tutorial-town departure, NPC routing/door traversal, every collision surface, all visual correctness, or total presentation latency. Those remain in Gates 4–5.

## Inspected captures

The following captures were inspected from `candidate-teleport-g3-ahead-12`:

- `ready.png`: real player viewport after the ahead-of-player approach; partial distant silhouette is visible.
- `close.png`: real player viewport at the exterior curtain wall with no modal loading.
- `courtyard_overview.png`: source-derived courtyard paving/foundation is present in the demanded packet.
- `castle_gatehouse_portcullis.png`: gate platform and portcullis are present.
- `home_interior_urban_civic_house_east_door_side.png`: generated fireplace, table/chairs, bed, and storage/furnishing geometry are present.
- `overview_3.png`: curtain-wall/tower geometry is present from an external side.

The captures also show incomplete distant/hidden city detail, large dark wall surfaces, sparse transitions, and visually abrupt partial geometry. Those are not concealed as success; Gate 4 owns spatial batching/detail tiers, resource census, day/night polish, and retirement/revisit settlement.

## Focused deterministic and lifecycle evidence

| Boundary | Command/report | Result | What it proves |
|---|---|---:|---|
| Immutable plan/preparation | `node tools/run-building-publication-preparation-contract.mjs --OutputDirectory artifacts/citadel-runtime-integration/publication-preparation-g3-10` | 145/145 PASS | timing-free deterministic plan, stable signature, exact dependencies, semantic milestones, typed parity |
| Locality packet order/cancellation | `node tools/run-building-scene-publication-job-contract.mjs --OutputDirectory artifacts/citadel-runtime-integration/scene-job-packet-order-g3-09` | 554 checks, 0 failures | packet ordering, sealed ownership, rolling demand, cancellation and physical receipts |
| Citadel service/reversal/rolling drain | `node tools/run-citadel-publication-service-contract.mjs --OutputDirectory artifacts/citadel-runtime-integration/publication-service-g3-34` | 155/155 PASS | ahead corridor determinism, retained reversal work, bounded view window, exact source binding, post-scene-ready drain |
| Terrain admission/edit identity | `node tools/run-citadel-terrain-admission-contract.mjs --OutputDirectory artifacts/citadel-runtime-integration/terrain-admission-g3-05` | 134/134 PASS | revision-bound admission, retirement, cancellation, and no prepared-to-absent gap |
| Sparse navigation publication | `node tools/run-regional-navigation-sparse-contract.mjs --OutputDirectory artifacts/citadel-runtime-integration/regional-navigation-sparse-g3-05` | 64/64 PASS | sparse priority, receipt retention, exact typed publication facts |
| Navigation lifecycle | `node tools/run-navigation-shutdown-lifecycle-contract.mjs` | 263 results PASS | worker cancellation, stale-result rejection, shutdown and acknowledgement lifecycle |
| Exact fluid payload | `node tools/run-exact-fluid-payload-contract.mjs --ReportPath artifacts/citadel-runtime-integration/exact-fluid-payload-g3-02.json` | 15/15 PASS | exact payload/save parity after incremental terrain snapshot change |
| Project compile | Godot 4.6.1 `--headless --path . --editor --quit` | PASS | changed scripts load and parse under the pinned engine |

Contracts are contract/service evidence, not live-gameplay acceptance. The headed run supplies movement, collision, zero-modal, physical publication, capture, and clean-process evidence. Neither evidence class is relabeled as NPC/pathfinding acceptance, and the protected route stack was not changed.

## Gate 4 entry

Gate 4 starts from the progressive publication authority established here. It must measure and reduce real scene resources, preserve source/group identity across detail replacement, inspect all required day/night views, and run at least 30 minutes with three leave/revisit retirement cycles and autosave enabled. The current partial visual gaps and resource settlement are open Gate 4 requirements, not Gate 3 regressions to mask with a full-source synchronous load.
