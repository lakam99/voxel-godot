# Exact shared-door unregistration

## Scope and authority

Started at clean `f0efe83` on `codex/citadel-visuals-clean`. The user explicitly
approved narrowly scoped per-door cleanup in the protected shared-door system,
preserving other towns and existing routing behavior. This is not permission
to repair the deferred NPC baseline or restart navigation replacement.

Main owns four additions to DoorPortal, DoorPortalService,
DoorTraversalExecutor and TrafficReservationService. The worker owns the new
synthetic DoorUnregistrationContract; an independent critic reviews read-only.
All read AGENTS.md and MANIFESTO.md. Existing API bodies remain unchanged.

- A live leaf is unregistered by registry instance identity and actual portal
  membership, not its possibly spoofed metadata. Removal happens before freeing.
- A grouped survivor retains its controller, logical state, crossing/hold/queue
  ownership and scheduled close. Physical leaf membership and bounds rebuild.
  Already-freed peers are pruned; this does not retroactively prove before-free
  cleanup for those peers.
- Only the final leaf retires the controller, portal, scheduled close and exact
  portal crossing records. Retained controller references are disarmed. No
  destruction event, durable door removal, or close callback is emitted.
- Traffic cleanup addresses the exact threshold and four directed edge resources,
  not a string prefix or actor-wide release. Current request/wait policy is
  removed only when attributable to this portal or a removed group with no
  remaining ownership elsewhere. Other portals, same-actor grants and newer
  unrelated requests survive.

This API is not yet connected to the citadel scene job. Smart-object representative
rebinding, balanced scene registration/unregistration, tree ownership hooks and
player-safe activation remain integration work. Recipes, furniture, geometry,
trees, routing algorithms, movement and save format are unchanged.

## Evidence

All paths below are under `artifacts/citadel-runtime-integration/` in this
worktree. Godot is 4.6.1 official `14d19694e`. Each run has fresh output paths
and is owned by `tools/run-godot-scene-watchdog.ps1`; no headed runs occurred.

```powershell
./tools/run-building-contract.ps1 -Contract DoorUnregistrationContract.gd -OutputDirectory artifacts/citadel-runtime-integration/door-unregistration-contract-03 -ReportEnvironment DOOR_UNREGISTRATION_OUTPUT
```

Final synthetic contract: **83/83**, complete, no failures; six recorded source
hashes match final code, including the unchanged DoorController. Parse and run
logs are clean, natural exit 0, zero owned processes, no forced cleanup. This
fixture uses real portal/controller/traffic services and real grants/queues;
executor crossing state is explicitly injected, not live NPC movement.

Controls cover null/unknown/spoofed/duplicate removal, before-free ownership,
fresh re-registration, grouped geometry/state preservation, freed-peer pruning,
prefix-similar portals, both same-actor latest-request orderings and direct
resource requests without portal metadata while retaining unrelated span grants.
Earlier `door-unregistration-contract-01` and `-02` passed their smaller 60/74
check sets; they are interim evidence, not substitutes for the final controls.
Progress is recorded in stdout; there are no gameplay screenshots or traces.

Before production edits, `door-unregister-baseline-{door,traffic}-01` ran the
unchanged suites at f0efe83: **48/48** and **38/38**. Door stderr is empty.
Traffic has a pre-existing 124-byte ObjectDB leak-at-exit warning despite natural
exit and zero remaining processes. It is preserved, not relabeled as clean.

After edits, `door-unregister-final-{contract,motor,nav_world,route,door,traffic}-01`
ran the same NPC scene headlessly, seed `atlas-1492`, time mode `both`, empty
case filter, fixed 60 fps, 45-second cap. The scene is
`res://scenes/testing/npc/NpcAutonomyTest.tscn`. Both seed variables match;
VOXEL_PLAYTEST=1, suite/report/progress/trace/screenshot paths, isolated userdata
and unique run token were supplied per suite. Each watchdog records the exact
Godot command. Reports and progress files were inspected, not just exit codes.

| Suite | Results | Baseline comparison | stderr bytes |
|---|---:|---|---:|
| Contract | 84/84 | binding checkpoint, exact stderr | 0 |
| Motor | 48/48 | binding checkpoint, exact stderr | 2788 |
| Nav world | 84/84 | binding checkpoint, exact stderr | 3276 |
| Route | 130/132 | binding checkpoint, exact stderr | 170166 |
| Door | 48/48 | pre-edit baseline, exact stderr | 0 |
| Traffic | 38/38 | pre-edit baseline, exact stderr | 124 |

The first four compare against `scene-publication-binding-npc-<suite>-01`.
Route retains the same day/night diagnostic exact-detour failures: four visits
against 32000 microseconds, with the same 244 engine error headers. Other
recorded NPC errors also remain byte-exact. This preserves the user's explicit
baseline exception; it is not a green NPC release. All six final jobs exited
naturally (route 1, others 0), proved zero owned processes and required no forced
cleanup. No new regression was observed in this coverage.

## Limits and review

The critic's static review passed registry identity, grouped survivors, final-leaf
retirement, exact-resource isolation and preservation of existing APIs. The
independent critic inspected final reports, source bindings, baseline comparisons
and these docs, and approved the focused seven-file API commit. No live player door interaction, NPC crossing,
complete production unload, ordinary citadel spawn, visuals or performance
acceptance is claimed. Prior publication timing overruns remain unresolved.
