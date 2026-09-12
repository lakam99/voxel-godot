# Citadel loading implementation record

Controlling plan: [investigation and implementation plan](C:/Users/arkam/.codex/visualizations/2026/09/12/01a09341-209a-75c0-ae6b-63c3dd2c4a0e/CITADEL_LOADING_INVESTIGATION_AND_PLAN_2026-09-11.md).

## Starting state

- Worktree: `voxel-biome-world-godot-citadel-visuals`, branch `codex/world-streaming-architecture`, HEAD `8f9c2cb`.
- Preserve the twelve existing tracked modifications and untracked `NavigationTileFilter.gd` listed in the September 11 handoff. They are the unpromoted worker integration and fixture migration, not a performance acceptance checkpoint.
- Known reproduction: world `atlas-3376622889`, region `-2,-2`, recipe `1393179273`, initial cell `-3334,-2666`.
- Investigation baseline: startup contracts 54/54; lifecycle contracts 144/144. Navigation-world compilation stopped at an inferred boolean in the migrated fixture. No live routing regression was established by that compilation failure.
- Baseline production remains frozen while the evidence agent repairs only the two explicit assertion types and executes the applicable existing runners.

## Work ownership and gates

| Package | Owner | Current state |
|---|---|---|
| A: baseline and evidence | evidence agent | Two mechanical fixture type corrections; baseline checks in progress |
| B: source repetition | generation agent | Read-only transaction/replay design until baseline gate passes |
| C/D: compact obligations and demanded publication | navigation agent | Read-only interface and dependency design until baseline gate passes |
| E: bounded capture, demand and acceptance | integrator | Read-only capture, scheduling and source-validity review |
| F: derived cache and remaining frame work | integrator | Read-only ownership and compatibility review |
| G: integrated acceptance | integrator with evidence agent | Pending implementation |

No concurrent performance benchmarks. Freeze source before comparisons. Unexpected results trigger evidence review and a decision before another edit/run cycle. Route search, movement, door execution and traffic stay protected; authorized navigation changes concern publication only.

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
