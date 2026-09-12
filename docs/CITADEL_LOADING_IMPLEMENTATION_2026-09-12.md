# Citadel loading implementation record

Controlling plan: [investigation and implementation plan](C:/Users/arkam/.codex/visualizations/2026/09/12/01a09341-209a-75c0-ae6b-63c3dd2c4a0e/CITADEL_LOADING_INVESTIGATION_AND_PLAN_2026-09-11.md).

Current status: implementation is active following the user's explicit authorization and the bounded baseline review. The final baseline collection is **11/17 suites passing**, with six failures preserved below; this is not a green release baseline. The source handoff passes 844 combined focused assertions and complete dense-navigation parity; staged audio passes 96 assertions. The first integrated headed checkpoint **failed the approach time limit**: frame stalls decreased, but startup did not improve and publication holds prevented arrival. Capture remains unpromoted pending reassessment. The PCM copy optimization is committed as `5a63c00`, the deferred handoff as `c59313a`, and opening/lower facade passed 31 typed parity checks. Integrated gameplay and performance acceptance remain outstanding. Earlier sections preserve historical failures and pending states; the terminal results below describe the current checkpoint.

## Starting state

- Worktree: `voxel-biome-world-godot-citadel-visuals`, branch `codex/world-streaming-architecture`, HEAD `8f9c2cb`.
- Preserve the twelve existing tracked modifications and untracked `NavigationTileFilter.gd` listed in the September 11 handoff. They are the unpromoted worker integration and fixture migration, not a performance acceptance checkpoint.
- Known reproduction: world `atlas-3376622889`, region `-2,-2`, recipe `1393179273`, initial cell `-3334,-2666`.
- Investigation baseline: startup contracts 54/54; lifecycle contracts 144/144. Navigation-world compilation stopped at an inferred boolean in the migrated fixture. No live routing regression was established by that compilation failure.
- At the start, baseline production was frozen while the evidence agent repaired the two explicit assertion types and executed the applicable existing runners.

## Work ownership and gates

| Package | Owner | Current state |
|---|---|---|
| A: baseline and evidence | evidence agent | Bounded collection complete; six failures preserved; frozen acquisitions complete |
| B: source repetition | generation agent | Opening/lower transaction changes pass 31 typed parity checks; lower phase has no measured speedup yet |
| C/D: compact obligations and demanded publication | navigation agent | Deferred handoff committed `c59313a`; focused and dense parity pass; grouped readiness not cut over |
| E: bounded capture, demand and acceptance | integrator | Retained-capture lifecycle165, nav-world86 and route132 pass; prior headed approach failure remains, candidate unpromoted |
| F: derived cache and remaining frame work | integrator/evidence agent | PCM copy committed; staged audio96/96 and reduced headed startup spike, individual file steps remain about42ms |
| G: integrated acceptance | integrator with evidence agent | Pending implementation |

No concurrent performance benchmarks. Freeze source before comparisons. Unexpected results trigger evidence review and a decision before another edit/run cycle. Route search, movement, door execution and traffic stay protected; authorized navigation changes concern publication only.

The next combined candidate batch covers the deferred dense handoff, cooperative local tile capture and staged audio. Capture scans registry inventory cooperatively and copies local collision facts, with conservative invalidation on global static, semantic or door revision changes. Optimal local invalidation and acceptance unification remain outstanding. Exact collision-filter equivalence, private-height-cache isolation, stale source identity and generator/volume absence-to-presence rejection are pending contract verification. Audio now reserves the original procedural and fallback objects before its first yield, then resolves one file per frame through the shared synchronous/staged job sequence; the earlier approximately 44ms atomic file measurement remains a limitation. Its new direct-service and real audio-owner contract will compare all 22 streams to the pinned pre-optimization evidence and exercise staged priming, missing-file fallback identity, cancellation and exit. These candidate descriptions are implementation status, not passing evidence or whole-game acceptance.

## Design corrections from implementation review

- Lower-facade input preparation already retains `independentRoots` once per completion transaction. The optimization target is the per-proposal proof copy/validation, full snapshots and support-delta comparisons; do not add a redundant root-context cache.
- Source description must precede dense navigation preparation, but description never acknowledges installed collision or usable doors.
- Resumable capture must retain one source identity across slices, invalidate stale partial work, and keep the existing authoritative terrain projection. A smaller outer time budget cannot interrupt the present 256-height-query loop.

## Final acceptance retained

The provisional cold target remains 90 seconds, with three controlled runs of the known seed and two fresh citadel seeds. Warm Continue is measured separately. Required playable radius is 64m plus actual dependency closure. At 1920x1080, retain sustained 60 FPS, p99 at most 33ms, no frame over 100ms and zero publication-caused movement holds. Mean cadence tolerance must be declared before final runs. Real interactions, traversal, edits/save/reload, night visuals, cancellation and clean process ownership are required; source signatures and synthetic checks alone cannot establish these outcomes.

## Baseline stop: protected route planner

The two explicit boolean fixture annotations compile. Navigation-world completed **86/86** at [report](../artifacts/citadel-runtime-integration/implementation-baseline-01/navworld/report.json), with natural clean exit recorded by [watchdog](../artifacts/node-tools/process-runs/godot-C4KGxf/watchdog.json).

The route suite aborted in unchanged `HierarchicalRoutePlanner.gd:425`: `has_method` was called on a String. The existing synthetic `test_route_profile_large_rejects_narrow_small_accepts` removes narrow surfaces for the large traversal profile and requests a start-span ID absent from that filtered graph. Expected: small profile completes and large profile returns unreachable. Actual: the missing String key falls through to the object-method branch and triggers a script error. This fixture is contract evidence, not live NPC acceptance. Report seed is `atlas-1492`; the actual scenario uses explicitly constructed two-cell geometry.

The planner has no working-tree diff and was last changed in `c5ae9d6`; the first observed failure in this campaign is on the baseline, before any loading production edits. The earliest introducing change has not been established. The route report's 26 passing results are partial, not a successful suite.

Exact command, from the citadel-visuals worktree (the existing wrapper default supplied `atlas-1492`; it was not a deliberately selected failing seed):

```powershell
node tools/npc/run-npc-route-tests.mjs -TimeMode Both -ReportPath artifacts/citadel-runtime-integration/implementation-baseline-01/route/report.json -ProgressPath artifacts/citadel-runtime-integration/implementation-baseline-01/route/progress.txt -TraceDir artifacts/citadel-runtime-integration/implementation-baseline-01/route/traces -ScreenshotDir artifacts/citadel-runtime-integration/implementation-baseline-01/route/screenshots *> artifacts/citadel-runtime-integration/implementation-baseline-01/route-wrapper.log
```

Evidence: [partial report](../artifacts/citadel-runtime-integration/implementation-baseline-01/route/report.json), [wrapper log](../artifacts/citadel-runtime-integration/implementation-baseline-01/route-wrapper.log), [engine error](../artifacts/node-tools/process-runs/godot-DqfpxH/stderr.log), [watchdog](../artifacts/node-tools/process-runs/godot-DqfpxH/watchdog.json). The watchdog terminated the owned job, exit 126, cleanupPassed=false, authoritativeZeroProven=true. No owned Godot process remains.

Under `MANIFESTO.md` ("If the baseline exposes any pathfinding regression, no implementation work begins. Stop, report the regression, and discuss it with the user first."), production implementation and further baseline runs are paused. Proposed bounded repair for explicit approval: require `start_span is Object` before calling `has_method`, preserving the existing known-string branch and nearest-span resolution. No routing edit has been made. Contract, door, broad, all-NPC and headed baseline remain outstanding.

## Preserved next-step design

- Start source optimization with one private ordered blueprint and local opening-head panel/append deltas, retaining all three local proofs and the public snapshot API. Then consume the lower-facade changed-panel plus three-beam delta directly. Initially retain the existing complete support scan; introduce spatial invalidation only after differential evidence supports it. Avoid a simultaneous native-kernel change.
- Regional obligations must include exact site-tree trunk bounds and visual/collision acknowledgement. The current compact index omits trees because the whole-site gate implicitly covers them.
- The current construction guard receives whole reservation bounds for every operation. Regional completion after player entry needs exact pending-group bounds through that same guard; removing the safety guard would be incorrect.
- Preserve source-key validation across incremental capture, including structure binding, semantic and door revision. Collision localization must retain original bucket record order and the exact clearance query halo.

No implementation package is promoted yet. The documentation records progress; the two fixture annotations remain with the existing uncommitted fixture migration.

## Authorized baseline repair

On September 12 the user explicitly approved the narrow route-planner guard and resumption. `resolve_start_key` now checks `start_span is Object` before calling `has_method`. Known String keys and the existing nearest-span resolution are unchanged.

The isolated existing `npc_route_profile_large_rejects_narrow_small_accepts` case passes **2/2**, day and night: [report](../artifacts/citadel-runtime-integration/implementation-baseline-02/object-guard/report.json), [watchdog](../artifacts/node-tools/process-runs/godot-DPkm5W/watchdog.json). Natural exit 0, no engine errors/warnings. This verifies the approved guard in the synthetic profile contract, not live route acceptance.

The resumed full route suite passed that case, then aborted on a distinct fixture setup error: detached `Node3D` instances were assigned/read through `global_position`. The engine correctly rejected those world-transform accesses. The partial progress count of 67 is not suite success; its report is empty. [Watchdog](../artifacts/node-tools/process-runs/godot-gW4onf/watchdog.json) records forced cleanup, exit 126, and authoritative zero owned processes.

After inspecting the related setup cohort, the evidence agent is attaching only fixture bodies/geometry that use world transforms to the existing runner before those accesses, preserving assertions and cleanup. Metadata-only detached fixtures need no change. This is a fixture lifecycle correction, with no further production routing change. Full baseline remains pending until the repaired cohort runs cleanly.

The lifecycle cohort subsequently passed the full route suite **132/132**, contracts **84/84**, and doors **48/48** under `artifacts/citadel-runtime-integration/implementation-baseline-03`. Clean watchdogs are respectively `godot-hoEOva`, `godot-TDmowD`, and `godot-CATCkC`. The broad gameplay baseline uses fresh random seed `atlas-1231420968`; its result is still pending. No loading production cutover has begun.

The opt-in render observer now retains absolute monotonic timestamps for its first 128 cadence intervals over 33ms and, independently, its worst interval even after that list fills. Existing histograms remain unchanged. First-draw delay is reported separately. Citadel startup-message records use the same clock, permitting correlation of the previously untimestamped startup maximum with loading events. These observer changes await headed verification and are not yet promoted.

The headless broad baseline aborted with wrong/uninitialized rendering RID and null dummy-renderer mesh errors, backtraced to the `FireLight3D.gd:104` light-energy setter. Ten passing assertions in an unfinished report do not establish success. Watchdog `godot-aCALLp` proves forced cleanup and zero owned processes. No light or rendering production code was changed in response: the backtrace may indicate where server work was observed, not its causal source.

Primary upstream research found [Godot issue 121949](https://github.com/godotengine/godot/issues/121949), reporting the same error sequence for threaded ArrayMesh creation under headless mode, and [fix 121958](https://github.com/godotengine/godot/pull/121958), merged for the 4.8 milestone to make dummy-renderer RID owners thread-safe. This supports a likely engine explanation; it does not independently prove this project's root cause. Existing local September 9/10 evidence also records this error category before the present changes. One same-seed `-Visible` broad run is being used as a renderer differential, with strict error detection retained. The failed headless run will not be relabeled as passing, and no engine upgrade is included.

Additional read-only findings for the implementation:

- The startup scene interval calls both `HostileVisualFactory._init` and `NpcVisualFactory.setup`. Each creates a separate `CharacterAssetRegistry`, whose setup synchronously parses and packs all 40 GLBs through `GLTFDocument`. This is a concrete candidate for the multi-second startup stall, still requiring measured stage costs. Preserve the generated asset pipeline and per-registry disabled-asset behavior if sharing immutable prepared scenes later.
- The authoritative character manifest contains 40 assets across 11 families, while the broad fixture retains its historical exact count of 30. Correcting that inventory expectation must preserve readiness and other assertions, not weaken it to an unbounded minimum.
- Regional tree source selection must match scene selection (`landscapeTrees`, otherwise `urbanPoc.treePlacements`); the existing terrain manifest uses only the latter. Use exact stored `treeRequest.collisionHeight` and `trunkRadius`, plus source rotation and the existing final visual receipt. Do not infer trunk collision from canopy height or silently replace a final visual receipt with a proxy.
- Add paving finish/foot coupling from `pavingFootingJoints.footPartIds` and aperture declaration membership from `masonryApertureSource` / `facadeApertures`. Current produced roof support chains already follow existing seat/anchor dependency fields; do not create another roof resolver or union all support edges into a whole-site component.

## Headed baseline classification and aggregate gate

The same-seed headed broad run (`node tools/run-playtest.mjs -Visible -Seed atlas-1231420968`, fresh report/progress/capture under `implementation-baseline-03/broad-headed`) completed **156/163**, with empty engine stderr and natural exit 1. Watchdog `godot-hni3EW` records clean cleanup and zero owned processes; wall time was 649.619 seconds. This distinguishes the headless rendering failure from the headed run, but the broad run is still failing.

Seven assertions failed: rescue atomic staging, subsequent home/guard behavior, town-exit slope apron, two procedural-tree readiness/authority checks, the obsolete exact character count, and the render-policy check while that tree remained pending. The manifest actually contains 40 assets and 11 families; the fixture count was corrected from 30 to 40 with readiness/family checks preserved. The apron assertion samples source heights rather than proving live traversal. The final screenshot was inspected, but its final forest/dialogue state does not prove an NPC or door sequence. Earlier evidence includes apron and tree-pending failure categories; it does not establish the cause of every current failure.

One focused replay retained the original tutorial assertions and added diagnostic capture before cleanup:

```powershell
node tools/run-playtest.mjs -Visible -Seed atlas-1231420968 -Only tutorial_start -ReportPath artifacts/citadel-runtime-integration/implementation-baseline-03/tutorial-staging-diagnostic/report.json -ProgressPath artifacts/citadel-runtime-integration/implementation-baseline-03/tutorial-staging-diagnostic/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/implementation-baseline-03/tutorial-staging-diagnostic/capture.png -TimeoutSeconds 900
```

It completed **21/23**, with exactly the rescue-staging and home/guard failures. The retained reason is **`no_rescue_site_candidate`**, returned before gate lookup, terrain/collision proof, actor staging or route commands. This establishes scenario-site infeasibility upstream of navigation. The later shelter failure may cascade from the failed mission/time transition; an independent routing defect has not been established. No rescue production change or further rescue replay is planned. Watchdog `godot-piDdCF`: natural exit 1, stderr empty, cleanup passed, authoritative zero owned processes, 234.483 seconds. The inspected screenshot shows the starter-room interior, not a rescue/NPC sequence.

The two observer scripts compile cleanly (`observer-compile-summary.json`, watchdogs `godot-rI6wAM` and `godot-uphjWo`); timing behavior still awaits the targeted citadel headed run.

The literal all-NPC aggregate was launched with `-TimeMode Both -StopOnFailure`, fresh seed `atlas-1607926605` and fresh aggregate report. Existing default child evidence was copied, never deleted, to `implementation-baseline-03/all-npc-before`, with a SHA-256 manifest. Contracts passed 84/84, then motor aborted because its synthetic runner is supplied as the NPC system but lacks both `npc_route_replans` and `npc_path_detours`, fields present on production `NpcSystem`. No production controller edit was made. The two fixture counters are being restored together, with assertions unchanged, before one focused motor check and the aggregate continuation. Its 36 partial motor results are not a passing suite; watchdog `godot-9s59Qo` proves forced termination and zero owned processes, with cleanupPassed=false.

The baseline gate remains open. The broad failures remain recorded; they are not waived by focused passes. Production loading changes have not begun. Diagnostic acquisition preparation may proceed independently, but frozen comparisons and Godot runs have one owner.

## Capture locality contract established by read-only review

The live collision index can supply sparse query buckets directly, preserving each bucket's record order and duplicate occurrences. Remove refreshed target-tile records using the existing owner-cell rule, then append the current target-tile block overlay in authoritative registry order using the existing inflation/index-margin arithmetic. Do not globally deduplicate by ID: the filter's own z/x/bucket traversal determines the first record for a duplicate ID and its rejection evidence.

The current pure filter queries the 3x3 bucket windows around core terrain cells and rounded emitted building-surface centers. Keep every Y level: the terrain collision predicate is deliberately XZ-only. Authored crossing links are appended by this filter, not live-collision queried. Any later consumer testing a long segment needs its full intervening query rectangle, not endpoint-only buckets. Exact per-building-tile collision manifests retain their separate segment/full-rectangle clearance contract.

There is no complete existing 2D live-block registry. Cached blocked/door/path cells collapse multiple Y entries and omit some kinds, while `create_block` permits explicit world-coordinate overrides. Initially retain a budgeted ordered registry scan; a derived indexed registry requires authoritative insertion/removal hooks and stable ordinals, not assumptions about height ranges.

A resumable capture must bind owner/main/generator lifetime, seed, tile/structure identities, the static cache epoch, terrain revision and immutable generated-site profile snapshot. Profile admission clears surface caches without incrementing terrain-volume revision; same-seed reset can also return that revision to zero. Tile source keys alone do not prove unchanged neighboring halo records. Recheck identities on resume and final seal, and retire stale work through the existing owner. Cursor-local projected heights must not populate shared unversioned caches after their source changes.

The headed diagnostic now also observes inherited synchronous startup setup calls and bounded stored queue/acceptance facts. It does not request sources, change priority, advance publication or calculate readiness. These facts distinguish absent acceptance, dirty/binding/descriptor/receipt mismatches and pending scheduling without creating a diagnostic navigation authority. These additions await Godot compilation and the frozen headed capture.

## Bounded fixture ownership batch

Motor passed **48/48** after restoring the two synthetic adapter counters. The next aggregate passed its first seven suites, then traffic passed **38/38** assertions but failed the strict exit gate because an inline detached `FakeMain` leaked (`godot-fLq5Uy`). That remained a failed suite. The response was one ownership audit across the remaining fixtures, not a production route change.

The resulting fixture cohort frees pure-height helper Nodes, gives nested fake main/player objects explicit parent ownership, reclaims detached fixture roots after each case, removes one unused simulation-service reference cycle, and attaches transform subjects before global-coordinate access. Existing assertions remain intact. Interaction already tracks its transient Nodes, and observation has no standalone Node allocations; neither needed a blanket change.

All eight affected fixture/observer scripts compile cleanly: `artifacts/citadel-runtime-integration/implementation-baseline-03/cohort-compile-summary.json` contains their owned watchdog paths. The subsequent aggregate passed its first eight suites including traffic, then exposed a threat Node whose helper reads its global position. That same lifecycle omission received one explicit runner attachment. Further automatic fixture repair was stopped: the final aggregate omits `-StopOnFailure` to collect every remaining result in one batch while retaining all child assertion, warning/error and cleanup gates.

```powershell
node tools/npc/run-all-npc-tests.mjs -TimeMode Both -Seed atlas-1607926605 -ReportPath artifacts/citadel-runtime-integration/implementation-baseline-03/all-npc-04/report.json -TimeoutSeconds 1800
```

The streaming fixture's required current world-signature artifact was absent. The existing generator was run with its required fixed seed, `node tools/run-world-signature.mjs -Visible -Seed atlas-1492 -TimeoutSeconds 900`. Actual output matched the untouched tracked baseline byte for byte: 423,894 bytes, SHA-256 `a66636ccd20fa67a5b2237fb97698a419eea9783435d04d9d93308dfc8b00044`. Watchdog `godot-IZmit8` records a clean headed exit. The actual output is archived as `implementation-baseline-03/world-signature-atlas-1492.json`; no reference was copied into a generated result.

The render timestamp observer is committed as `bbfcd55`; its new cadence fields await headed measurement. The citadel fixture's synchronous setup spans and stored queue/acceptance sampling passed compilation and independent read-only review: at most 32 setup spans and 256 demand samples of eight tiles, with sampling cost recorded separately. Sampling invokes no source preparation, readiness or queue advancement and retains no geometry.

For any measured character-resource startup fix, [Godot 4.6 background-loading guidance](https://docs.godotengine.org/en/4.6/tutorials/io/background_loading.html) requires checking threaded completion before retrieving a resource, since premature retrieval blocks. Its [thread-safety guidance](https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html) also distinguishes detached scene construction from rendering-node/thread-model constraints and GPU synchronization. Simply moving the current GLTF scene construction to another thread is not an established safe or stall-free fix. Preserve the existing generated assets and exact material/mesh behavior; measure the new setup spans before choosing staged preparation, immutable scene sharing or a validated resource-loading path.

## Collection findings relevant to scope

The final collection reached interaction 45/45, streaming/save 42/42 and soak 26/26 with no assertion failures. Behavior aborted after 78 partial passing results because its synthetic `FakeMain` lacks both seed fields consulted by deterministic goal selection; this is incomplete fixture evidence, not a passing suite. No further automatic repair was made during collection.

The go-home fixture completed 13/13 assertions on `atlas-1607926605`. Its inspected open/closed-door screenshots are very dark, so they do not independently make the complete sequence visually clear. The real tutorial opening run failed before Mira observation, but its recorded movement event identifies the gate: `terrainCollisionHold=true`, `terrainCollisionHoldFrames=120`, `proofReason=regional_dependencies_incomplete`, zero slide collisions, and unchanged player position 1.35m from the next waypoint. The route itself was ready with an eight-sample collision proof. This is direct evidence of the existing in-scope regional loading gate holding the player, not evidence to justify changing NPC routing or movement.

The shared headed wrapper runs the pre-launch acceptance guard, but does not stamp its result into the gameplay report. Consequently completed visual children fail the required `forbiddenCallSelfScan.status == passed` report-integrity gate (missing on go-home, `passed-by-wrapper-before-launch` on the tutorial runner). Separate guard files corroborate that the preflight ran; they do not retroactively make the aggregate pass. Morning-outside and final-rescue each reported 1/1 gameplay assertions, with acceptance still failing this integrity gate. Morning setup stages the scenario and proves only subsequent departures. Preserve these distinctions when the final aggregate completes; no report will be edited into a pass.

## Terminal baseline collection

The final `all-npc-04` command above completed in **844.743 seconds: 17 suites, 11 passes, six failures**. Its [aggregate report](../artifacts/citadel-runtime-integration/implementation-baseline-03/all-npc-04/report.json) retains the exact child commands. Clean synthetic suites comprise contract 84, motor 48, nav-world 86, route 132, repair 34, door 48, avoidance 32, traffic 38, interaction 45, streaming/save 42 and soak 26 assertions: **615 total**. `Both` does not replace the separately listed Transition checks, and the literal registry does not cover every optional release runner.

| Failed suite | Terminal evidence and limit |
|---|---|
| behavior | 78 partial assertions, then missing synthetic seed fields caused `String(null)` in deterministic goal selection. Owned error termination, not a pass. |
| real_tutorial_playthrough | Two failures before door input/Mira observation. Ready collision-backed route was held by `regional_dependencies_incomplete`; acceptance images were never reached. |
| go_home_visual | 13/13 gameplay assertions and required images; failed guard-result stamping. |
| real_tutorial_morning_outside | 1/1 staged-morning assertion and images; failed guard-result stamping. |
| real_tutorial_final_rescue | 1/1 staged-rescue assertion and required images; failed guard-result stamping. Earlier quest completion and player placement are fixture setup, not proved gameplay. |
| town_job_cycle_visual | Owned timeout at 300 seconds; unfinished 16/16 partial daytime assertions, no completed night/morning evidence, plus guard-result stamping failure. |

The aggregate's 1800-second option limits child Node execution but is not forwarded to the headed child (`aggregate-runner.mjs:13–33`); the shared wrapper supplies a 300-second Godot timeout. This is shorter than the town fixture's unoverridden 430-second default. No extension or replay was made after the final collection.

The [process summary](../artifacts/citadel-runtime-integration/implementation-baseline-03/all-npc-04-process-summary.json) maps all 17 sequential jobs to exact watchdogs. Every job proves zero owned processes. Behavior (`godot-I7xmd6`, overall 126) and town (`godot-0NRqv5`, overall 125) retain forced cleanup and `cleanupPassed=false`; other jobs exited naturally with empty stderr. The [archive manifest](../artifacts/citadel-runtime-integration/implementation-baseline-03/all-npc-after-04/manifest.json) hashes 75 copied files, 47,958,570 bytes. Earlier aggregate attempts and the seven broad failures remain preserved.

Inspected morning and rescue captures also show “Preparing nearby world…”. That text reports the runtime movement-publication gate; it does not by itself prove that startup was skipped. Niko's final rescue image clearly shows an actor inside beside shut door panels; Sera is visible outside at the gate. These static views do not independently prove the entire crossing/clearance sequence. No remaining NPC fixture was repaired or rerun after this collection.

## Frozen headed 13 measurement

```powershell
node tools/run-citadel-candidate-teleport-playtest.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-loading-baseline-13 -Seed atlas-3376622889 "-CandidateRegion=-2,-2" "-SpawnCell=-3334,-2666" -Resolution 1920x1080 -SkipTutorial -ForceDaytime -ForceClearWeather -CaptureNavigationRejections -StartupTimeoutSeconds 180 -TimeoutSeconds 600
```

One Godot process ran after correcting two pre-launch shell/output-name checks. The [report](../artifacts/citadel-runtime-integration/candidate-teleport-loading-baseline-13/report.json) and [verification](../artifacts/citadel-runtime-integration/candidate-teleport-loading-baseline-13/verification.json) record natural exit 0, no engine errors/warnings, unchanged frozen sources, successful cleanup and zero owned processes. This is a selected-initial-location diagnostic with tutorial/day/weather controls, not ordinary-menu, uninterrupted exploration or live NPC acceptance.

| Measurement | Result |
|---|---:|
| Startup | 130.504 s |
| Approach | 31.648 s; 16 of 31 sampled states held |
| Approach total-frame cadence | p99 139.6 ms; max 272.976 ms |
| Approach rendering GPU | p99 12.5 ms; max 14.018 ms |
| Scene publication | 1,107 advances; 3.590745 s active CPU; 10.141316 s between advances |
| Largest scene atomic operation | 30.651 ms, masonry |
| Spatial preparation | 22.257483 s, including 20.421231 s navigation preparation |
| Navigation source | 42 tiles; 157,496 samples; 161,814 surfaces |

The **2,766.65 ms** worst cadence interval is timestamped at 6,217,892–8,984,542 microseconds. The inherited audio setup occupies **2,461.28 ms**, at 6,218,020–8,679,300: it starts just 128 microseconds into that interval. This refutes the earlier character-registry hypothesis for this particular stall. Hostile and NPC setup took 18.902 and 29.152 ms; tutorial and HUD took 46.185 and 41.746 ms. No screenshot export overlaps the startup maximum. The observer's own maximum callback was 10.333 ms; its bounded first-128 spike list drops 266 later spikes, while the independent worst interval and histograms remain recorded. Per-phase tables also have bounded capacity; late diagnostic work can fall into `overflow`.

During approach, tile `-209,-171` appears in 18 consecutive one-second demand observations, 140.370–158.020 seconds: absent acceptance, no dirty flag, deferred, queue priority false, regional priority zero. The requested and queued source keys match. Queue age rises from 313 to 919 frames while its position moves 46→43→47…7→17 and workers remain active. This is direct evidence of a retained movement dependency waiting behind other publication work, not a stale accepted descriptor in those samples. All 16 held approach samples report `regional_dependencies_incomplete`, with `navigation_accepted_source_pending` for that tile or the initial `-209,-167` tile.

The exact historical `candidate-teleport-navigation-filter-12` report records startup 132.663 s, approach 32.391 s and 16/31 sampled holds. Both it and headed13 end with `scene_ready` but **`gameplayReady=false`, `door_activation_pending`**. Source signature `b29eabb4fb8e28b3bb0ff53325e69ec2a72d05797280793b130bb49401427752` and source binding remain unchanged. Green diagnostic completion is therefore not completed Citadel gameplay.

Inspected [initial spawn](../artifacts/citadel-runtime-integration/candidate-teleport-loading-baseline-13/initial_spawn_ready.png) and [courtyard](../artifacts/citadel-runtime-integration/candidate-teleport-loading-baseline-13/courtyard_overview.png) show continuous terrain and the expected Citadel, with the nearby-world hold message. The [gatehouse landing view](../artifacts/citadel-runtime-integration/candidate-teleport-loading-baseline-13/castle_gatehouse_wall_stair_landing_00.png) is clipped/occluded by dark geometry and cannot prove a usable landing or traversable route. The total-frame cadence includes gameplay/script/physics waits; GPU timings are a separate, much smaller metric. No steady-state or cold-machine benchmark claim is made.

## Frozen source and navigation acquisitions

All six diagnostic scripts compiled before acquisition; [compile summary](../artifacts/citadel-runtime-integration/implementation-baseline-03/citadel-diagnostics-compile-summary.json) records their watchdogs. The following commands ran sequentially without source edits between them or concurrent Godot work:

```powershell
node tools/run-citadel-structural-policy-capture.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-structural-policy-baseline-01
node tools/run-citadel-facade-phase-replay.mjs -CaptureDirectory artifacts/citadel-runtime-integration/candidate-structural-policy-baseline-01 -OutputDirectory artifacts/citadel-runtime-integration/candidate-facade-phase-baseline-01
node tools/run-citadel-dense-navigation-baseline.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-dense-navigation-baseline-01
```

Every acquisition passed its checks, owned process cleanup and before/after source inventory audits. Capture intercepted 4,322 parts and 178 furnishings from pinned source32 inputs; captured input SHA-256 is `2aa1de5303ea96fdad744a14e17ee5ac6b6a3bbd57f3698ce5dee11cfd0fadbb`. Facade replay captured seven exact typed input/result/physical-proof artifacts. Its [report](../artifacts/citadel-runtime-integration/candidate-facade-phase-baseline-01/report.json) contains all hashes and 24 passing checks. Opening took 7.482002 s, lower facade 16.095666 s, full facade replay 26.820205 s; independent opening/lower physical checks took 2.380638/2.863598 s. Lower output retained 64 accepted, zero rejected panels. Diagnostic callback intervals and extra validation are not uninstrumented runtime timing.

The [dense oracle](../artifacts/citadel-runtime-integration/candidate-dense-navigation-baseline-01/report.json) passed 24 checks with 42 tiles, 161,814 surfaces, 157,496 samples and zero unresolved crossing IDs. Worker preparation took 29.693383 s, including 17.440379 s navigation work. `navigation-tiles.bin` is 123,624,224 bytes, SHA-256 `402373fe260be85d7977cbc156d1a69a922cdb14795459bae8cbb32718cb1ecc`. Semantic SHA-256 is `b6587259c1524fdcc5e8c5e94ac8d838dc3ca73016da88363edfed9f5120d2c9`; comparison excludes only root preparation time, preserving ordered typed tile contents. This is a source oracle, not live navigation acceptance. The source freeze was explicitly released only after the final inventory audit. Acquisition tooling is committed as `a3aa607`.

## Measured PCM audio copy change

Commit **`5a63c00`** changes only the PCM data copy in `AudioEffectsSystem.load_pcm_wav`: the existing validated/clamped byte range is copied by `PackedByteArray.slice(data_offset, data_offset + data_size)` instead of a GDScript loop over every byte. RIFF parsing, fallback evaluation, stream metadata, random calls, asset paths, playback/priming and ownership are unchanged.

An isolated subclass timed each call to the existing loader through `build_streams`, then hashed every produced stream. Baseline and candidate each ran once in a fresh owned headless process with warm filesystem caches, the same diagnostic seed and unchanged source assets. [Baseline report](../artifacts/citadel-runtime-integration/audio-pcm-baseline-01/report.json), [candidate report](../artifacts/citadel-runtime-integration/audio-pcm-candidate-01/report.json), and [comparison](../artifacts/citadel-runtime-integration/audio-pcm-candidate-01/comparison.json) show:

| Loader work | Before | After |
|---|---:|---:|
| Entire `build_streams` | 2,394.381 ms | 140.947 ms |
| Rain PCM | 331.347 ms | 13.575 ms |
| Tutorial music PCM | 978.266 ms | 43.635 ms |
| Second-day music PCM | 1,030.075 ms | 42.977 ms |

All 22 produced stream byte hashes and format/rate/channel/loop properties match exactly, as do all eight WAV source assets, daytime track order, successful-load decisions and the next global RNG draw. The [evidence manifest](../artifacts/citadel-runtime-integration/audio-pcm-parity-evidence-01/manifest.json) binds exact before/after source snapshots and the [diagnostic used](../artifacts/citadel-runtime-integration/audio-pcm-parity-evidence-01/AudioPcmLoaderDiagnostic.gd). Both calls used the existing `runGodotProcess` helper with `--headless --path <project> --script <diagnostic>`, 45-second timeout, and `AUDIO_PCM_DIAGNOSTIC_REPORT` pointing to each fresh report; each was preceded by `--check-only` with the same script. Their `parse.json` and `process.json` records link to natural-exit, zero-owned-process watchdogs. No playback or whole-game improvement is claimed from this direct-service test. The remaining 141 ms total still warrants staged startup work and integrated headed verification.

The first urgency propagation batch compiled `MainCore`, `RegionalNavigationPublication`, `NpcRouteCoordinatorAdapter` and both existing focused fixtures. [Startup](../artifacts/citadel-runtime-integration/loading-urgency-contracts-01/startup.json) passes **54/54** and [lifecycle](../artifacts/citadel-runtime-integration/loading-urgency-contracts-01/lifecycle.json) **147/147**, including three new priority/context/age/sequence checks. These synthetic passes do not replace the failed baseline or integrated performance acceptance. Further changes are collected into coordinated batches, with no automatic repeat of the entire NPC baseline.

## First source transaction parity result

```powershell
node tools/run-citadel-facade-phase-parity.mjs -BaselineDirectory artifacts/citadel-runtime-integration/candidate-facade-phase-baseline-01 -OutputDirectory artifacts/citadel-runtime-integration/candidate-facade-phase-parity-01
```

The [typed comparison](../artifacts/citadel-runtime-integration/candidate-facade-phase-parity-01/report.json) passes **31 checks**, including complete opening/lower public output equality, caller/input immutability, exact independent physical proofs and cancellation before commit. Opening took **5.833741 s** against 7.482002 s at baseline; lower took **16.111749 s** against 16.095666 s, which is no meaningful improvement. The new 34.535-second total includes additional cancellation tests and cannot be compared directly with baseline replay total. No production source acceptance or whole-game timing claim follows from this single exact-fixture differential.

[Comparison evidence](../artifacts/citadel-runtime-integration/candidate-facade-phase-parity-01/comparison-evidence.json) records 1,183 unchanged hashed files and 1,171 unchanged inventory entries. The worker exited naturally with code 0 and clean owned-process cleanup at 06:53:07.264 UTC; the source audit completed at 06:53:08.021 UTC. A later edit to the unused capture draft has filesystem timestamp 06:54:58.940 UTC, after that audit window. The successful source gate is preserved as recorded; no restoration, report alteration or replay was used to address the coordination concern. The source freeze was then explicitly released.

## Combined handoff, capture and staged-audio checkpoint

The first combined compile stopped at the derived `NavigationPublicationWorker._prepare_source` signature after its base gained an optional fourth callable. Audio owner and fixture compiled; no assertions ran. [Batch01](../artifacts/citadel-runtime-integration/loading-combined-contracts-01/summary.json) and its archived `runner.mjs` preserve the failure. The navigation owner audited all derived overrides and added only the unused optional argument to the tile worker, preserving its body. The engine-error watchdog proved zero owned processes after termination; that run was not a clean functional exit.

[Batch02](../artifacts/citadel-runtime-integration/loading-combined-contracts-02/compile-summary.json) then compiled all22 owners/fixtures. Its audio report failed44 comparisons because historical JSON numbers decode as floats while the current stream-property dictionaries contain integers. Every failed serialized actual/expected pair is identical; all48 other checks passed. A separate ObjectDB exit warning was also preserved at `artifacts/node-tools/process-runs/godot-iwNrWJ/stderr.log`. Neither the failed report nor the warning was rewritten as passing evidence.

While sources remained unchanged, the independent stages continued once in [Batch03](../artifacts/citadel-runtime-integration/loading-combined-contracts-03/summary.json): startup54, lifecycle152, nav-world86, route132, NPC contracts84, building worker125, building preparation113 and Citadel service98, all passing (**844 assertions**). NPC fixtures used explicit `-TimeMode Both -Seed atlas-1492` and fresh report/progress/trace/screenshot paths. The exact batch driver used the existing Node helpers; all child watchdogs show natural exit0, empty stderr and clean zero-owned-process proof. Before/after source and inventory audits remained unchanged across1172 entries. The new capture checks establish exact unchanged-filter output and duplicate order, private height-cache isolation, and stale world/generator/volume identity rejection; they do not establish live throughput or readiness.

```powershell
node tools/run-citadel-dense-navigation-baseline.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-dense-navigation-handoff-01
```

The subsequent [dense comparison](../artifacts/citadel-runtime-integration/candidate-dense-navigation-handoff-01/parity-comparison.json) passes24 acquisition checks and preserves the complete semantic SHA `b6587259c1524fdcc5e8c5e94ac8d838dc3ca73016da88363edfed9f5120d2c9`, all42 ordered tile records, field order and field totals. The123,624,224-byte candidate artifact hashes to `30dd4eb65699c6fd7d85a0a6615fe256c366a79692edf146f0451946e2b021ee`; only root preparation time is excluded from semantic comparison. Preparation32.294716s/navigation19.220793s versus baseline29.693383s/17.440379s is not a speedup claim. The source audit and owned process cleanup pass.

Staged audio is committed as **`9cb0a16`**. The audio fixture correction validates each integer schema field as finite and exactly integral before conversion, preserving all byte hashes, string/boolean types and RNG comparisons. Negative checks reject fractional values, changed hashes, changed byte counts and incorrect boolean types. The one corrected verbose [audio owner contract](../artifacts/citadel-runtime-integration/audio-startup-contract-01/report.json) passes **96/96** with natural exit0, empty stderr, no verbose leak/error/warning lines, clean owned-process cleanup and an unchanged source inventory. The earlier ObjectDB warning did not recur; no production lifecycle repair or explanation for that isolated warning is claimed.

The contract uses production audio players and priming with one asset per advance, plus explicitly synthetic missing-file fixtures for fallback/cancellation. All22 historical stream byte hashes and properties, original global RNG consumption before the first yield, insertion/track order and exact reserved fallback object identities pass. Six cancellation boundaries and tree exit reject resumed work and release playback. Warm direct-service measurements: synchronous build135.111ms; pre-yield object/player reservation36.571ms;14 separate frame steps with largest41.793ms. Priming steps are below0.6ms. This proves the audio owner contract, not audible quality or the full Main startup/exit experience.

## First integrated headed checkpoint: approach failed

```powershell
node tools/run-citadel-candidate-teleport-playtest.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-loading-checkpoint-01 -Seed atlas-3376622889 "-CandidateRegion=-2,-2" "-SpawnCell=-3334,-2666" -Resolution 1920x1080 -SkipTutorial -ForceDaytime -ForceClearWeather -CaptureNavigationRejections -StartupTimeoutSeconds 180 -TimeoutSeconds 600
```

The same-seed controlled diagnostic [report](../artifacts/citadel-runtime-integration/candidate-teleport-loading-checkpoint-01/report.json) failed `approach_time_limit`. [Verification](../artifacts/citadel-runtime-integration/candidate-teleport-loading-checkpoint-01/verification.json) records natural exit1, zero engine errors/warnings, unchanged sources, clean cleanup and zero owned processes. No repeat followed this failure. Both runs use fresh isolated userdata; filesystem/driver cache warmth is uncontrolled, and neither is a cold-machine benchmark.

| Observation | Headed13 baseline | Checkpoint01 |
|---|---:|---:|
| Startup |130.504s|131.865s|
| Preparing nearby world message span |43.698s|52.402s|
| Synchronous audio setup span |2461.280ms|35.818ms|
| Whole-run worst cadence |2766.650ms|435.485ms|
| Whole-run p99 cadence |131.5ms|36.7ms|
| Whole-run intervals over100ms |178|10|
| Approach p99 / maximum cadence |139.6 /272.976ms|49.7 /173.967ms|
| Approach elapsed / result |31.648s, reached|45.042s, timeout|
| Remaining distance to visual bounds |6.81m|29.53m|
| Sampled approach holds |16/31|30/45|

The new35.818ms audio span measures pre-yield setup/reservation. Full elapsed time from audio setup start to tutorial setup start is250.991ms, including yielded file loading/priming. The new435.485ms worst cadence interval ends108 microseconds before audio setup starts, so it is earlier system/scene setup. Overall cadence distributions have different phase mixes because the failed checkpoint skipped the later inspection-camera captures; the approach-specific metrics are the narrower comparison. Approach GPU p99 is6.9ms and maximum7.346ms, well below total cadence. The targets remain unmet despite the large stall reduction.

Publication lost useful throughput. During45 one-second approach demand samples, the worker was idle in41 (baseline0/31); its prepared counter rose73→116 over44.444s (baseline171→288 over30.960s). Of301 observed pending tile facts,282 carry queue priority, with maximum age1649 frames. These bounded observations are not a complete queue inventory or continuous utilization trace. At170.916s, missing tile `-209,-173` is clean, deferred, prioritized, age1315 and queue position66, with matching requested/regional source and idle worker. At175.978s, missing tile `-208,-172` is clean, nondeferred, prioritized, age1458 and position2, again with matching source and idle worker. Neither has an accepted entry; these samples do not demonstrate a stale-accepted predicate disagreement.

The last five one-second movement observations span4.036s at an identical position, all held by `regional_dependencies_incomplete` / `navigation_accepted_source_pending` for `-208,-172`. Sampling does not prove every intervening physics frame. Scene publication remains `scene_ready`, **`gameplayReady=false`, `door_activation_pending`**, with the same source signature `b29eabb4fb8e28b3bb0ff53325e69ec2a72d05797280793b130bb49401427752` and binding `60d35570a40a438f232245e244ab5e4115883a0ff9bb4444588afabcf09705de`.

Capture step maximum is32.765ms. Recorded live/terrain capture section maxima64.976/158.276ms sum work across slices, not individual-frame duration. Per-tile capture profiles from the later navigation inspection are absent because approach failed first; worker `discardedStale=1` is not a capture-restart count. Current telemetry cannot quantify all cancelled capture CPU work. Scene publication remains roughly unchanged:1134 advances,3.605521s CPU,10.140795s between advances,29.906ms maximum atomic step and819 overruns. The compact descriptor handoff has not removed the full dense42-tile work from the current readiness path.

Inspected [failed exterior view](../artifacts/citadel-runtime-integration/candidate-teleport-loading-checkpoint-01/failed.png) shows continuous terrain and Citadel walls with the persistent nearby-world loading message. It does not show successful entry, usable doors, or complete courtyard/stair routes. The checkpoint is a regression in approach completion and triggers reassessment of capture retention, queue throughput and demanded publication before further source changes or acceptance runs.

## Retained-capture handoff correction: focused verification only

Read-only reassessment identified an ordering defect: sealing a capture immediately queued its retirement before the shared worker could accept the sealed input. Deferred input could then lose its retained owner through queue ordering and cache pressure. The candidate now retains that same capture/input through the actual accepted receipt, detaches live aliases after sealing, and releases the slot on matching acknowledgement, cancellation, stale identity or terminal failure. Foreground arbitration visits an ineligible owned slot once without consuming unrelated demand. This addresses a demonstrated ownership defect; its contribution to the headed39.424-second completion plateau has not been measured in a new live run.

The three unchanged production owners compiled cleanly in [retention01](../artifacts/citadel-runtime-integration/capture-retention-contracts-01/compile-summary.json). That batch stopped on an inferred boolean in the new fixture; its failure remains preserved. After explicit fixture typing, [retention02](../artifacts/citadel-runtime-integration/capture-retention-contracts-02/lifecycle.json) ran164/165: the map-baseline comparison captured a previous fixture's asynchronously retiring map. The correction uses the existing physics/process/physics synchronization before capturing the baseline and preserves exact final-map equality, now recording both ID sets.

Final focused results:

- [Lifecycle165/165](../artifacts/citadel-runtime-integration/capture-retention-contracts-04/lifecycle.json), including eight real adapter/coordinator/worker/NavigationServer handoff checks. Two queued tiles reach actual acknowledgement with the same sealed input retained; wrong-binding, cancellation, stale source, reset and shutdown cases pass. Baseline/final map IDs are both empty.
- [Nav-world86/86](../artifacts/citadel-runtime-integration/capture-retention-contracts-03/npc-nav-world/report.json) and [route132/132](../artifacts/citadel-runtime-integration/capture-retention-contracts-03/npc-route/report.json), with explicit `-TimeMode Both -Seed atlas-1492` and fresh report/progress/trace/screenshot paths. They ran once and were not repeated after the map-baseline fixture correction.

The existing Node driver dispatched `tools/npc/run-npc-nav-world-tests.mjs` and `tools/npc/run-npc-route-tests.mjs` through `runTool`. Final lifecycle used `runGodotProcess` with `--headless --path <citadel-visuals-project> --script res://scripts/testing/NavigationShutdownLifecycleContractRunner.gd`, timeout120s, and `VOXEL_NAVIGATION_SHUTDOWN_REPORT` set to `capture-retention-contracts-04/lifecycle.json`; its [process record](../artifacts/citadel-runtime-integration/capture-retention-contracts-04/process.json) retains the exact owned launch. All three final processes exited naturally with code0, no engine warnings/errors, clean owned-zero proof and unchanged1172-entry source/inventory audits. No headed repeat followed; the failed integrated report remains unresolved acceptance evidence. Compact/demanded C/D publication, the lower-facade bottleneck, measured cache/upload work and the full final acceptance matrix remain outstanding.
