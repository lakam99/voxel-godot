# Phase R01 Report - Smart Object Stale Node Lifetime

Branch: `npc-pathfinding/repair-01-smart-object-lifetime`

Base stack commit: `697e8af5731146d6f43b8fd8d189e30f0ab78b84`

Status: PASS for R01 acceptance gates.

## Implementation Summary

- Hardened `SmartObjectService` so smart-object registration node access stores `registration.node` locally, checks null, checks `is_instance_valid(node)`, and only then performs `Node3D` casts, metadata reads, position reads, scoring, filtering, or slot logic.
- Added authoritative stale registration handling through `notify_object_removed`, `mark_registration_stale`, and `registration_is_live`.
- Added lifecycle cleanup by connecting registered node-backed smart objects/resources to `tree_exiting`.
- Stale registrations now release reservations, clear their node, mark unavailable/depleted/stale metadata, remove themselves from all smart-object indexes, increment revision, and invalidate query cache.
- Resource query and candidate scoring paths skip stale IDs without throwing and only return live `Node3D` candidates.
- Interaction tests now clean transient nodes through the common `outcome()` path so queue-free stress cases do not leave ObjectDB leak noise.

## Focused R01 Coverage

Added interaction suite cases:

- `npc_interaction_stale_registered_resource_ignored`
- `npc_interaction_queue_free_resource_query_no_script_error`
- `npc_interaction_stale_resource_unindexed`
- `npc_interaction_stale_resource_reservation_released`
- `npc_interaction_query_cache_invalidates_on_resource_removal`
- `npc_interaction_forager_query_after_harvest_no_crash`

Focused run:

```powershell
VOXEL_NPC_TEST_SUITE=interaction
VOXEL_NPC_TIME_MODE=both
```

Artifact: `artifacts/npc/reports/interaction-r01-both-foreground.json`

Result:

- `resultCount=26`
- `failureCount=0`

Forbidden log scan artifact: `artifacts/npc/logs/interaction-r01-both-foreground.log`

Forbidden strings scanned:

- `SCRIPT ERROR`
- `previously freed instance`
- `Invalid get index`
- `Invalid call`
- `ObjectDB instances leaked`

Result: `0` matches.

## Regression Gates

Route suite:

- Artifact: `artifacts/npc/reports/route-r01-both.json`
- `resultCount=38`
- `failureCount=0`

Repair suite:

- Artifact: `artifacts/npc/reports/repair-r01-both.json`
- `resultCount=32`
- `failureCount=0`

Behavior suite:

- Artifact: `artifacts/npc/reports/behavior-r01-both.json`
- `resultCount=22`
- `failureCount=0`

Broad playtest:

- Artifact: `artifacts/npc/reports/playtest-r01.json`
- `finished=true`
- `passed=true`
- `results=181`
- `failures=0`

Wrapper log scan artifacts:

- `artifacts/npc/logs/playtest-r01-wrapper.out.log`
- `artifacts/npc/logs/playtest-r01-wrapper.err.log`

Forbidden-string scan result: `0` matches.

Static check:

```powershell
git diff --check
```

Result: no whitespace errors; Git reported only existing LF-to-CRLF working-copy warnings for touched GDScript files.

## Acceptance Mapping

- Niko/forager resource queries cannot crash on freed nodes: covered by `npc_interaction_queue_free_resource_query_no_script_error` and the forbidden-string scan.
- Query results contain only live `Node3D` objects or valid metadata-backed candidates: covered by `live_registration_node_3d`, `registration_matches_query`, `query_resource_nodes`, and the focused interaction report.
- Depleted/removed resources are not returned as available: covered by stale ignored, unindexed, cache invalidation, and post-harvest query cases.
- Stale resource reservations are released: covered by `npc_interaction_stale_resource_reservation_released`.
- Existing interaction, behavior, route, repair, and broad playtest gates remain green: covered by the artifacts listed above.

## Stack Note

This branch is intentionally stacked on the R00 characterization branch. The newly registered real tutorial playthrough runner remains red until later repair phases address the live Mira movement stall. Do not merge the stack to `master` until the later phases make the full runner set green.
