# Preserve ordinary structures during landmark admission

On `codex/citadel-visuals-clean`, starting at `62333f6`, extract the existing
standalone location/type/dimension sequence into `StandaloneStructureCandidate`.
`StructureSystem` calls it and restores its exact continuation RNG state before
the original flatness check and construction. Existing towns/tutorial selection
and geometry are unchanged. No new standalone policy or seed source is added.

This lets citadel admission reject overlap with raw ordinary candidates without
testing their flatness against terrain already changed by the citadel. Current
source-audited XZ influence bounds include foundations, roofs, porches and
camp/mine approaches. Current mines do not carve a descending tunnel. The bounds
are not lighting propagation, mesh halos, render AABBs or exact support masks.
Future source extensions must update the influence contract.

## Evidence

`artifacts/citadel-runtime-integration/standalone-contract-01/report.json`:
80/80 checks across 61,728 region cases, independent old-sequence candidate and
continuation-RNG equality. Fixed seeds plus the fresh seed recorded in the report;
0.760 seconds. Full scene-watchdog command/seed/source hashes are in that run's
launch/report/watchdog artifacts. It ran headlessly through
`tools/run-godot-scene-watchdog.ps1`, scene argument `--script` followed by
`res://scripts/testing/buildings/StandaloneStructureCandidateContract.gd`.
Empty error logs, natural exit 0 and authoritative owned-process zero.

The independent read-only critic approved this extraction and audited the current
foundation, porch, roof and camp/mine approach extents. This approves source
contracts, not rendered-world or citadel-spawn acceptance.

Same-condition NPC rerun: `terrain-profile-npc-02`, `atlas-1492`, both time modes,
`res://scenes/testing/npc/NpcAutonomyTest.tscn --fixed-fps 60`, headless watchdog.
Contract 84/84, motor 48/48, nav-world 84/84, route 130/132. The route's two
detour-budget failures remain the explicitly deferred baseline failures.
Motor/nav-world/route logs retain their baseline error categories, including
`npc_route_replans`, off-tree transforms and String/`has_method`; this is not a
clean NPC or live-gameplay pass. No new assertion failure or error category was
observed. Reports, progress tokens and cleanup were independently inspected.

The first rerun `terrain-profile-npc-01` omitted freshness-token/progress launch
variables and failed those two harness checks. It is retained as failed and
superseded by the correctly configured rerun, not treated as a game regression.
