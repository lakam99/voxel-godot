# World Streaming Maturity Gate 2 — Corrected Profile And Native Decision

Date: 2026-09-14  
Branch: `codex/world-streaming-maturity-migration`  
Profiled base commit: `81537056cab2bf983b79891d626854b12e900b56`  
Gate result: **COMPLETE; PERFORMANCE ACCEPTANCE REMAINS PENDING; GATE 3 HAS NOT STARTED**

## Outcome

Gate 2 replaces the old aggregate-only diagnosis with attributed source, demand-planning, publication, autosave, and movement evidence. The corrected profile selects **no native kernel yet**.

The first Gate 3 work is algorithmic and architectural:

1. build one stable compact Citadel plan/spatial/dependency index from immutable source data;
2. stop rescanning all 4,098 groups for every quantized view change;
3. seal progressive partitions so early silhouette, gate, courtyard, and accessible-home work can publish without waiting for the full 56-second recipe;
4. retain those results across turns and re-profile the remaining coarse pure kernels;
5. consider GDExtension only if a deterministic immutable kernel remains material after work elimination.

Native raster/navigation tuning is explicitly not selected. The prior exact Citadel native-chunk research already found missing required surfaces/crossings and synchronization errors, while this Gate 2 trace attributes the current blocker to Citadel source and publication planning instead.

## Instrumentation added

- `CitadelPublicationService` now keeps bounded samples for scene/publication units and exposes a one-shot percentile profile. Ordinary `stats()` remains compact and does not sort or copy the sample rings.
- Demand planning is split into owner closure, complete view window, view rank/merge, candidate sort, dependency selection, result assembly, navigation merge, job handoff, and status copy.
- The headed Citadel fixture captures the one-shot publication-stage profile only at terminal report construction. It does not use the profile to influence success.
- Autosave snapshot construction now attributes inventory, ordinary systems, terrain volume, subsurface, story, NPC job facts, exploration, and player blocks without changing the save envelope.
- The performance monitor's bounded section-name capacity is 192 rather than 128 so late, infrequent autosave owners are not silently omitted after startup instrumentation fills the original limit.

## Test machine and run conditions

- Godot `4.6.1-stable (official)`, hash `14d19694e0c88a3f9e82d899a0400f27a24c176e`
- Forward+ Vulkan, NVIDIA GeForce RTX 5060 Ti
- 1920×1080 for headed Citadel and normal-runtime measurements
- One measured Godot workload at a time
- Fixed Citadel seed `atlas-3376622889`, region `(-2,-2)`, recipe seed `1393179273`, initial spawn cell `(-3334,-2666)`
- Normal-runtime runs chose fresh seeds through visible Main Menu → New Game input as required by the runner
- Artifact folders are ignored by Git; decisive compact findings are preserved here

## Source-only recipe profile

Command shape, repeated three times with fresh owned directories:

```powershell
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-g2-20260914-0N -Seed atlas-3376622889 -CandidateRegion "-2,-2" -ExpectedRecipeSeed 1393179273 -ExpectReady
```

The migration plan's example nested `artifacts/world-streaming-maturity/g2/recipe-01` path is rejected by the current runner. The runner requires a fresh `candidate-recipe-*` directory directly under `artifacts/citadel-runtime-integration`; no Godot process launched for the rejected invocation.

| Run | Recipe | Independent physical validation | Source export | Report/physical export | Largest callback interval |
|---|---:|---:|---:|---:|---:|
| `candidate-recipe-g2-20260914-01` | 56,038.013 ms | 1,202.801 ms | 59.309 ms | 562.163 ms | 3,322.320 ms |
| `candidate-recipe-g2-20260914-02` | 54,421.155 ms | 1,202.397 ms | 57.154 ms | 560.099 ms | 3,045.303 ms |
| `candidate-recipe-g2-20260914-03` | 56,988.793 ms | 1,219.405 ms | 52.839 ms | 573.989 ms | 3,371.008 ms |
| p50 / p95 / p99 / max | 56,038.013 / 56,988.793 / 56,988.793 / 56,988.793 ms | 1,202.801 / 1,219.405 / 1,219.405 / 1,219.405 ms | 57.154 / 59.309 / 59.309 / 59.309 ms | 562.163 / 573.989 / 573.989 / 573.989 ms | 3,322.320 / 3,371.008 / 3,371.008 / 3,371.008 ms |

All three runs:

- passed the public recipe and full independent physical-integrity check;
- produced exactly 4,570 building parts and 176 furnishing parts;
- emitted a 6,837,868-byte source artifact and 14,263,484-byte physical-proof artifact;
- executed 1,522,437 progress callbacks;
- retained the same semantic candidate/seed/region/recipe identity.

The raw `input.bin` and `source.bin` SHA-256 values differ between runs because the serialized diagnostic payload contains measured survey timing (`maxColumnUsec`, `maxSliceUsec`, `preparationUsec`, and `workUsec`). The semantic request identity is stable, but the raw diagnostic SHA is therefore not a valid cache key and is not claimed as deterministic-output parity. Gate 3 must define a timing-free canonical typed signature and differential parity before retaining/reusing prepared partitions.

The largest attributed source intervals include support resolution (8.530 s aggregate), lower-façade panel work (6.422 s), compound placement structure proof (4.286 s), shop recipe preparation (3.322 s), and later structural work (16.633 s). These callback intervals are coarse wall attribution, not exclusive CPU profiles; they select progressive source decomposition and a later re-profile, not immediate line-for-line native ports.

## Live Citadel demand and publication profile

Final command:

```powershell
node tools/run-citadel-candidate-teleport-playtest.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-g2-profile-20260914-02 -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600
```

Result: PASS, clean owned shutdown, no setup teleport. The title UI is bypassed by this fixture, but production New Game systems, ordinary observer admission, real player physics, ordinary viewport look input, and held W/Shift movement are used.

Movement is real and explicit:

- 26/26 approach samples record ordinary W pressed;
- approach time 30.535 s;
- player moved from `(-4500.945, 19.27862, -3599.28)` to `(-4489.012, 41.4631, -3732.507)`;
- final distance to Citadel visual bounds 7.492 m;
- zero modal-loading frames during the approach;
- all headed checks passed.

Main callback cadence in this diagnostic was p50 3.017 ms, p95 8.580 ms, p99 12.328 ms, max 15.594 ms. Those rolling Main callback values do not include the 574.577 ms synchronous Citadel call itself and are not OS presentation cadence acceptance. The service's maximum observed total was 577.603 ms.

### Attributed demand costs

| Source/function | Scale/frequency | p50 | p95 | p99/max | Accumulated | Decision |
|---|---:|---:|---:|---:|---:|---|
| `_refresh_scene_group_demand` inclusive | 3,864 calls; 74 expensive | 0.002 ms | 0.004 ms | 433.752 / 574.197 ms | 31,664.832 ms | Keep cheap revision hits; eliminate expensive rebuilds |
| `_packet_foreground_plan` inclusive | 74 × 4,098 groups | 430.057 ms | 516.754 ms | 569.408 ms | 31,311.122 ms | Stable retained plan/index; no native yet |
| retained owner closure | 75 calls, at most 141 publishable IDs | 295.220 ms | 368.607 ms | 380.085 ms | 21,130.638 ms | Index spatial/tile membership and dependency closure once |
| complete view window | 75 × 4,098 groups | 134.799 ms | 168.755 ms | 189.245 ms | 10,410.637 ms | Query bounded spatial candidates, not whole city |
| view rank and merge | 75 × 8,196 ranked rows (two view owners) | 82.216 ms | 105.473 ms | 122.637 ms | 6,361.675 ms | Deduplicate equivalent normalized view intents; rank only indexed candidates |
| selection/dependency closure | 75 calls, at most 202 ranked rows examined | 26.462 ms | 38.365 ms | 42.285 ms | 1,788.830 ms | Precompute immutable dependency closures |
| candidate sort | 75 calls, up to 4,098 rows | 15.190 ms | 24.786 ms | 27.467 ms | 1,216.766 ms | Partial/bucket selection over bounded candidates |
| first-useful semantic scan | 75 × 4,098 groups plus furnishing source | 7.125 ms | 8.310 ms | 10.668 ms | 543.423 ms | Compute once per source revision |
| job demand handoff | 74 × roughly 4,098 selected/deferred IDs | 4.439 ms | 6.580 ms | 6.868 ms | 337.930 ms | Retain compact immutable sets; batch/copy only on change |
| result assembly | 75 × 4,098 group census | 2.809 ms | 4.192 ms | 6.372 ms | 224.083 ms | Avoid rebuilding full deferred array on camera-only change |
| status copy | 74 × roughly 4,098 IDs | 0.055 ms | 0.086 ms | 0.115 ms | 4.285 ms | Already negligible |
| scene job advance | 47 calls | 1.047 ms | 2.970 ms | 3.970 ms | 54.594 ms | Existing slice/budget; no native |
| transaction selection | 3,862 calls | 0.005 ms | 0.009 ms | 0.040 / 0.195 ms | 22.171 ms | Already negligible |

The two dominant inclusive children account for the parent: owner closure 21.131 s plus the view window 10.411 s explains the 31.311 s plan total within timer nesting/overhead. This is not an engine submission or scene-node mutation bottleneck.

The installed first-useful packet had 228 foreground groups, 3,857 deferred groups, 15 completed physical groups, one registered door, seven building parts, eight furnishing parts, and an estimated active transaction size of 36,864 bytes. Direct per-function allocation counts are not exposed by GDScript. Rather than inventing them, this gate records exact work units and serialized/packet byte sizes; Gate 3 must add process/allocation census around the compact index and sealed partition candidates before any native admission decision.

## Autosave ownership

Commands:

```powershell
node tools/run-normal-runtime-performance-pass.mjs -Resolution 1920x1080 -DurationSeconds 120 -TimeoutSeconds 300 -ReportPath artifacts/world-streaming-maturity/g2/autosave-profile-01/report.json -ProgressPath artifacts/world-streaming-maturity/g2/autosave-profile-01/progress.txt
node tools/run-normal-runtime-performance-pass.mjs -Resolution 1920x1080 -DurationSeconds 100 -TimeoutSeconds 300 -ReportPath artifacts/world-streaming-maturity/g2/autosave-profile-02/report.json -ProgressPath artifacts/world-streaming-maturity/g2/autosave-profile-02/progress.txt
node tools/run-normal-runtime-performance-pass.mjs -Resolution 1920x1080 -DurationSeconds 100 -TimeoutSeconds 300 -ReportPath artifacts/world-streaming-maturity/g2/autosave-profile-03/report.json -ProgressPath artifacts/world-streaming-maturity/g2/autosave-profile-03/progress.txt
```

All three runs used visible Main Menu → New Game input, fresh random seeds, autosave enabled, normal player automation, real physics/collision, and no fixed-FPS mode. Each completed one asynchronous save and failed the existing 2 ms main-thread autosave threshold, which remains a release blocker.

The final run (`atlas-87808560`) used the final provider-order-preserving instrumentation. It travelled 912.685 m, displaced 124.474 m, changed direction 11 times, recorded 2,232 live collision samples, and observed all 36 requested jumps. Its snapshot profile is one real autosave sample:

| Snapshot owner | Time |
|---|---:|
| full `create_save_snapshot` | 4.278 ms |
| `WorldGenerationSystem.save_terrain_volume_deltas` | 3.264 ms |
| player block snapshot | 0.507 ms |
| weather/tutorial | 0.155 ms |
| NPC durable job facts | 0.144 ms |
| story | 0.100 ms |
| ordinary systems bundle | 0.035 ms |
| inventory | 0.017 ms |
| subsurface | 0.012 ms |
| exploration | 0.004 ms |
| background JSON stringify/write | 4.827 ms (worker; not main-frame work) |

The earlier 100-second run (`atlas-94490393`) travelled 827.370 m with 11 direction changes and 2,098 live collision samples; its snapshot max was 3.872 ms and background JSON max 4.062 ms. The earlier 120-second run (`atlas-78959477`) travelled 766.649 m with 13 direction changes and 2,306 live collision samples; its snapshot max was 3.596 ms and background JSON max 4.495 ms. Gate 1's five-minute run had three completed saves, a 6.164 ms snapshot max, and 5.274 ms background JSON max. The terrain-volume delta snapshot is the selected owner for Gate 3 algorithm/retained-state work; JSON remains on the worker and is not selected for native migration.

The 100-second run also observed one unrelated 34.439 ms Main callback spike attributed to existing NPC routine planning. Gate 2 did not modify the protected route stack and does not claim that outlier as resolved.

## Bottleneck and native decision table

| Candidate | CPU/wall/thread and repeat identity | End-to-end impact | Classification and chosen action | Rejected alternatives |
|---|---|---|---|---|
| Citadel owner closure + view ranking | Main-thread wall time; 74–75 rebuilds for one immutable 4,098-group source; two equivalent-scale view owners | 31.3 s accumulated and 574 ms live spikes | **Eliminate work → retain stable spatial/tile/dependency/semantic index → bounded query/partial selection** | Native sort/rank would accelerate redundant work; larger frame budget would worsen stalls; view throttling alone would leave bad worst cases |
| Full Citadel recipe | Worker wall time; same semantic request is 54.4–57.0 s; 4,570 parts; 6.84 MB output; raw artifact SHA includes timing metadata | Source cannot keep ahead of a sprint/reversal and cannot produce early silhouette | **Progressive sealed partitions, retain completed immutable work, define timing-free canonical identity, then re-profile** | Immediate wholesale C++ port before stable partition/schema; caching raw timing-bearing artifact SHA; synchronous load gate |
| Physical validation | Worker wall time, 1.20–1.22 s; 4,570 parts; 14.26 MB proof | Small relative to recipe and off Main | **Keep worker implementation; measure partition-local validation later** | Native migration now |
| Scene packet publication | Main thread but sliced; job advance max 3.970 ms; current packet estimate 36,864 bytes | Within the Citadel 4 ms claim; not source of 574 ms spike | **Keep bounded scene owner** | Native scene mutation or direct server bypass |
| Terrain-volume save delta snapshot | Main-thread wall time, 3.264 ms of 4.278 ms in the final real sample; repeats each autosave when dirty | Violates 2 ms autosave snapshot threshold | **Retain/update canonical durable delta snapshot incrementally; copy compact immutable payload at save** | Moving live world/node reads to worker; native JSON; disabling autosave |
| JSON stringify/write | Worker wall time, 4.062–5.274 ms | No synchronous main-frame write; job completes | **Keep asynchronous worker** | Native serialization without evidence; synchronous low-load write |
| Native raster navigation | Prior candidate, not a current measured owner | Prior exact Citadel research lost required topology and produced synchronization errors | **No work in G3 unless new authoritative geometry evidence appears** | Finer raster tuning, fallback seams, engine fork/module |

Selected native kernels for Gate 3: **none**. This is an affirmative measured decision, not a claim that GDScript will always suffice. Gate 3 reopens native admission only after the stable plan and sealed-partition algorithms remove redundant work and expose a coarse deterministic immutable kernel with canonical typed input/output.

## Numeric comparator and Gate 3 acceptance goals

No verified formerly-smooth Citadel control with equivalent seed/build/cache conditions was found. Gate 2 therefore establishes explicit absolute envelopes rather than treating the regressed 127.627-second snapshot as success.

### Loading comparator

- Cold normal New Game at 1920×1080: three controlled known-seed samples plus two fresh seeds in Gate 5; menu New Game input to gameplay ready must be at most 90 s for every sample. This is a roughly 15% envelope over the two corrected fresh observations (75.280 s and 77.935 s), not a target chosen from the old regression.
- Warm Continue at equivalent camera/state: at most 45 s and no more than 10% slower than its paired cold-stage work that is actually reusable.
- Loading UI must remain responsive; no single loading-stage Main callback above 33 ms and no modal re-entry after gameplay readiness.

### Citadel progressive preparation

Measured representative sprint velocity is approximately 15.4 m/s and the current view intent reaches 180 m, leaving about 11.7 s without reversal margin. Gate 3 targets:

- first stable silhouette within 8 s of source demand;
- usable gate/approach collision within 16 s;
- visible courtyard within 20 s;
- one accessible furnished home within 30 s;
- current demanded closure within 45 s;
- full source may finish in background but must drain within 90 s when continuously retained;
- reversal/side approach must reuse completed partitions and must not restart full source work.

### Main-thread cadence and autosave

- Citadel demand plan/query: p99 at most 1.5 ms, max at most 2.0 ms, no whole 4,098-group scan on a camera-only revision, and no more than 512 candidate rows per view query before dependency expansion.
- Scene job advances remain at or below the existing 4 ms Citadel claim inside the shared 6 ms gameplay envelope.
- Main callback/presentation release criteria remain p99 at most 33 ms, no recurring frame above 33 ms, and no frame above 100 ms; Gate 5 must measure actual presentation separately.
- Autosave snapshot max at most 2.0 ms; terrain-volume delta capture max at most 1.0 ms; background JSON is reported separately and may not block gameplay.
- Player traversal evidence must report nonzero travel and displacement, ordinary input samples, collision samples, and zero modal-loading frames during the Citadel approach. A stationary runner does not satisfy these goals.

## Verification ledger

- Project compile smoke after final provider-order-preserving instrumentation: PASS; watchdog `artifacts/node-tools/process-runs/godot-DiShgJ/watchdog.json`.
- Citadel publication service contract after final profiling instrumentation: 150/150 checks PASS with clean cleanup; `artifacts/citadel-runtime-integration/publication-service-g2-profile-20260914-02/report.json`.
- Fixed-seed headed Citadel profile: PASS with real movement and clean cleanup; `artifacts/citadel-runtime-integration/candidate-teleport-g2-profile-20260914-02/report.json`.
- Source-only recipe runs: 3/3 PASS with clean owned cleanup; directories `candidate-recipe-g2-20260914-01` through `-03`.
- Normal-runtime autosave profiles: expected FAIL on the existing 2 ms autosave threshold. All three reports contain real movement/collision evidence and completed async saves; the final provider-order-preserving report is `artifacts/world-streaming-maturity/g2/autosave-profile-03/report.json`.
- Tutorial save compatibility after final snapshot instrumentation: 9/9 contract checks PASS; watchdog `artifacts/node-tools/process-runs/godot-5gWRnl/watchdog.json`.
- Voxel terrain save parity: INCONCLUSIVE; headless renderer RID initialization failed before assertions and no report was produced; watchdog `artifacts/node-tools/process-runs/godot-erCJ4H/watchdog.json`.
- World signature: INCONCLUSIVE for the same pre-assertion headless renderer RID initialization failure; no signature was produced; watchdog `artifacts/node-tools/process-runs/godot-zztNTr/watchdog.json`.

This gate does not prove continuous tutorial-town-to-Citadel travel, NPC route/door acceptance, all Citadel visuals, deterministic partition parity, memory settlement, 30-minute soak, release presentation cadence, or final save/Continue acceptance. Those remain later-gate requirements.

## Gate 3 entry

Gate 3 may begin only from this decision record. Its first implementation is the stable timing-free compact plan/index and sealed progressive source partitions. It must not begin with C++, native raster tuning, a custom engine build, a larger synchronous budget, or a cache keyed by the timing-bearing diagnostic SHA.
