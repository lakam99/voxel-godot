# N6 navigation dependency inventory

Status: read-only inventory at `db0bff7`. No route code or behavior changed; no N6 or Gate 5 acceptance claimed.

## Current source and proof boundaries

| Fact | Current owner and boundary |
| --- | --- |
| Terrain and structure source for a tile | [`GeneratedWorldNavigationAdapter.build_navmesh_tile_snapshot`](../../scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd) requires terrain publication, then obtains [`StructureSystem.navigation_tile_sources`](../../scripts/StructureSystem.gd) and a live collision snapshot. Its tile key combines static, semantic, door, terrain, load and building-source revisions. This is the adapter to replace with N3/N4 pinned source identities after N5 collider installation. |
| Collision and occupancy facts | The adapter's `build_snapshot`, `navigation_capture_static_collision_candidates` and collision record indexes currently scan/cache engine collision and dynamic occupants. [`NavigationTileCapture`](../../scripts/npc_ai/navigation/NavigationTileCapture.gd) cursorizes capture; [`NavigationPublicationSource`](../../scripts/npc_ai/navigation/NavigationPublicationSource.gd) seals owned values for workers. A native query may replace CPU preparation only after it consumes the same effective physical snapshot and exact installed collision revision. |
| Structure support and semantics | [`BuildingNavigationManifestBuilder`](../../scripts/buildings/BuildingNavigationManifestBuilder.gd) emits ordered walkable supports, doors, vertical links and seam/interior passages from blueprint parts; [`BuildingNavigationTileProducer`](../../scripts/buildings/BuildingNavigationTileProducer.gd) turns those into tile surfaces. [`BuildingNativeSupportQueries`](../../scripts/buildings/BuildingNativeSupportQueries.gd) already calls native `BuildingSupportKernel` for a subset of blueprint support questions, but the blueprint and manifest still own generated facts. N4 must provide stable native geometry/semantic IDs before this can be a single source. |
| Publication and accepted tile | [`RegionalNavigationPublication`](../../scripts/world/RegionalNavigationPublication.gd) retains demand, advances bounded tiles, validates crossing obligations and checks current accepted receipts. [`NavmeshWorldService`](../../scripts/npc_ai/navigation/NavmeshWorldService.gd) registers prepared snapshots and checks accepted tile state. Navigation readiness must remain downstream of N5 physical acknowledgement, including cancellation and retirement. |
| Route proof and movement | [`CollisionBackedRouteSubstrate`](../../scripts/npc_ai/routing/CollisionBackedRouteSubstrate.gd) owns bounded search/candidate preparation and snapshot validation. [`NpcRouteAuthorityV2`](../../scripts/npc_ai/routing/NpcRouteAuthorityV2.gd) calls live collision probing before `mark_ready` and issues the route lease. Movement, door crossing and traffic remain with their existing controllers; a native candidate or graph result is never final movement admission. |

## Dependency order and candidate pure-core slices

1. **Wait for N3/N4/N5 receipts.** A nav artifact needs an immutable effective terrain/feature source identity and the exact current physical installation for its tile and intersecting supports/doors. A source hash without owner generation, installed collision revision and cancellation epoch cannot certify route readiness. Preserve the present ready/pending/failed classifications while those dependencies are unresolved.
2. **Port deterministic source preparation first.** Candidate pure-core work includes ordered static collision records, support/clearance spatial indexes, walkable span/edge extraction and tile-boundary/seam ownership from the pinned N3/N4 snapshot. Compare typed ordered output, negative coordinates, vertical spans, doors, stairs and support semantics against the current adapter/manifest, not hashes alone. Godot scene mutation and actual physics probing remain adapters.
3. **Then port CPU topology/query work behind existing authority.** Candidate work includes source-revision-keyed tile graph building, route search/proof preparation and approach-cell candidate indexing. Preserve search ordering, budgets, cancellation, lease identities and readiness classes. Actor reservations, dynamic occupants, current door state, final live collision/footprint proof and policy filtering stay at the route authority boundary. Never cache actor-specific final approach slots globally.

The [MANIFESTO](../../MANIFESTO.md) protects topology/publication, route proof and leasing, motors, doors, traffic and recovery. The native migration expressly authorizes the scoped N6 source/query port in the [migration handoff](../../CODEX_NATIVE_WORLD_BACKEND_MIGRATION_HANDOFF_2026-09-17.md); it does **not** authorize changed movement, door sequencing, traffic ownership, route classifications, or actor-specific shortcuts. If a baseline regression appears, preserve the seed/evidence and stop before changing protected code.

## Focused verification map

Run an unchanged-baseline comparison before N6 implementation, then repeat after each source/query cutover with the same seeds and actual native physical receipts:

```powershell
node tools/run-voxel-terrain-navigation-publication-mapping-contract.mjs
node tools/run-regional-navigation-sparse-contract.mjs
node tools/run-navigation-shutdown-lifecycle-contract.mjs
node tools/npc/run-npc-contract-tests.mjs -TimeMode Both
node tools/npc/run-npc-nav-world-tests.mjs -TimeMode Both
node tools/npc/run-npc-route-tests.mjs -TimeMode Both
node tools/npc/run-npc-repair-tests.mjs -TimeMode Both
node tools/npc/run-npc-door-tests.mjs -TimeMode Both
node tools/npc/run-npc-traffic-tests.mjs -TimeMode Both
node tools/npc/run-all-npc-tests.mjs -TimeMode Both
```

These are contract/service evidence. For generated homes, doors and routing acceptance, run `node tools/npc/run-real-tutorial-playthrough.mjs` and applicable town job/home headed playtests with ordinary input and inspect trajectory, door sequence, strict interior, source/physical/nav revisions and screenshots. Do not cite direct helpers, teleport setup or metadata as live movement proof.
