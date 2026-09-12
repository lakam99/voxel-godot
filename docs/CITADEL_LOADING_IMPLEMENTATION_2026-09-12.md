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
