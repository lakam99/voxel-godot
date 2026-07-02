# True 3D Cave Biome Audit

Date: 2026-07-02
Branch: `codex/global-subsurface-caves`
Controlling plan: `CODEX_TRUE_3D_CAVE_BIOME_PLAN.md`

This audit began as Phase 0 of the true 3D cave biome migration. It records the original offenders and their migration targets so future work does not drift back into cave-mouth patching or placed-cave behavior.

## Current Status

The cave implementation has been migrated to the true 3D cave-biome path described in `CODEX_TRUE_3D_CAVE_BIOME_PLAN.md`.

The natural terrain and cave interiors are now sampled through `WorldGenerationSystem.sample_cell/sample_world`. The chunk mesher emits the exterior as a natural projection of the 3D solid/air boundary, then emits cave/subsurface void boundaries from the same density/biome volume into the same mesh and collision asset. The accepted mesher must preserve the game's natural/stylized terrain silhouette; visible cube-face voxel terrain is a regression, not a valid final 3D implementation. Cave biome air exists before decoration and without `StructureSystem` cave placement. `SubsurfaceSystem` is only an excavation/volume-edit adapter. `CaveInteriorBuilder` no longer owns shell geometry. Mesh and collision are tagged and verified as coming from the same `volume_sample_extraction` path.

The static gate is now expected to pass. If it fails, treat that as a regression toward the banned architecture unless the finding is a documented false positive and the gate is updated with a stricter rule.

## Hard Regression Rule

No future cave implementation work should continue if it tunes a cave mouth, portal, arch, rim, cap, facade, mound patch, hidden quad, or shell as a separate feature. Fixes must go through the authoritative `(x,y,z)` volume field, biome rules, or volume surface extraction.

## Original Offender Inventory

| File | Current Offender | Classification | Migration Target | Phase |
| --- | --- | --- | --- | --- |
| `scripts/MainPlaytestTools.gd` | `build_chunk_mesh`, `terrain_surface_height_cell`, `terrain_vertex_local*`, `terrain_normal_for_cell*`, `terrain_quad_hidden_for_cell`, `add_chunk_skirts` build a 2D heightfield surface and hide quads for cave openings. | delete/replace | Replace with chunk volume surface extraction over `(x,y,z)` solid/air samples. Mesh and collision must come from the same extracted volume. | 2 |
| `scripts/MainPlaytestTools.gd` | `terrain_color_for_cell`, `add_skirt_vertex`, prop/detail placement use `(x,z)` biome and height decisions. | temporary adapter | Query `WorldGenerationSystem.sample_cell/sample_world` and derive top exposed surfaces from the 3D volume. Chunk `(cx,cz)` indexing may remain only as indexing. | 5 |
| `scripts/MainPropFactory.gd` | `height_at_world`, `ground_height_at_world`, `terrain_height_cell`, `base_height_cell`, `natural_base_height_cell`, `biome_at_cell`, `terrain_material_id_for_cell` remain generation-facing `(x,z)` APIs. | temporary adapter | Convert callers to 3D ground probes/material samples. Any temporary method must immediately delegate to the 3D sampler and own no terrain, biome, or cave decision. | 1, 5 |
| `scripts/MainInterface.gd` | Interface still exposes legacy `(x,z)` terrain/biome stubs and `build_chunk_mesh`. | temporary adapter | Replace interface contracts with 3D sample/probe contracts. Keep legacy stubs only during migration and fail static audit if they gain authority. | 5 |
| `scripts/WorldGenerationSystem.gd` | `surface_height_for_cell3`, `base_surface_height_for_cell3`, `natural_surface_height_for_cell3`, `surface_height_at_world`, and `surface_height_for_cell` still make height authoritative. | temporary adapter/offender | Replace with density/sample API where height is derived from volume when needed. | 1 |
| `scripts/WorldGenerationSystem.gd` | `register_cave_plan`, `cave_plan_records`, `active_plans_from_records`, `cave_air_value_at_world_from_records` make caves depend on external plans. | delete/replace | Generate cave biome/density fields inside `WorldGenerationSystem` from seed and `(x,y,z)` position. No StructureSystem plan should be required for cave samples. | 1, 3 |
| `scripts/WorldGenerationSystem.gd` | `cave_mound_overlay`, `surface_patch_quad_cut_by_cave_pipe`, `cave_surface_point_opens_to_air`, `surface_quad_hidden_for_cell3` patch the surface path around cave openings. | delete | Remove hidden surface cuts and mound overlays as separate cave-mouth authority. The cave entrance must be only a solid/air boundary in the volume. | 2 |
| `scripts/SubsurfaceSystem.gd` | `register_cave_plan`, `rebuild_cave_patch`, `cave_patch_nodes`, `cave_patch_plans`, `build_cave_volume_mesh`, `add_cave_voxel_volume_to_surface_tool` create a separate cave mesh/collision path. | delete/repurpose | Remove as cave authority. Keep this system only for player excavation if it writes deterministic 3D volume edits consumed by the shared chunk mesher. | 2, 3 |
| `scripts/SubsurfaceSystem.gd` | `add_cave_surface_shell_to_surface_tool`, `cave_shell_*`, `cave_extraction_*`, `cave_patch_cells*`, `terrain_quad_hidden_for_cell`, `terrain_material_override_for_cell`, `ground_height_at_world` duplicate terrain/cave authority. | delete | Delete shell/patch/hidden-quad authority. Ground/collision must come from shared volume extraction. | 2, 4 |
| `scripts/StructureSystem.gd` | `update_caves`, `cave_plan_for_region`, `best_cave_plan_candidate`, `make_cave_plan`, `build_cave`, `apply_cave_terrain_edits`, `generated_caves`, `cave_records`, `cave_active_plans` make caves placed structures. | delete/replace | StructureSystem may discover and decorate cave-biome regions, but it must not create cave geometry, cave air, terrain cuts, collision, floors, ceilings, walls, or mouths. | 3 |
| `scripts/StructureSystem.gd` | `cave_terrain_cells`, `cave_terrain_hole_cells`, `terrain_material_override_for_cell`, `terrain_quad_hidden_for_cell`, `cave_ground_height_at_world`, `cave_mouth_portal_cells`, `cave_terrain_pipe_cut_cells`, `cave_terrain_opening_cells` are cave-mouth/terrain patch authority. | delete | Replace with volume samples and surface extraction. There should be no cave mouth portal metadata used to open terrain. | 3 |
| `scripts/StructureSystem.gd` | `build_cave_supports`, `place_cave_wall_torch`, `cave_wall_*`, `cave_floor_y_*`, `cave_ceiling_y_*` use plan/shell geometry for decorations. | temporary adapter | Decorations may remain only after they query existing cave-biome surfaces from the 3D volume. Decoration removal must leave cave geometry intact. | 4 |
| `scripts/CaveInteriorBuilder.gd` | `build`, `build_visual_mesh`, `build_collision_mesh`, `add_carved_volume`, `add_boundary_walls`, `add_wall_strip`, `floor_point`, `ceiling_point`, `cave_volume_value`, `rendered_shell_*` define independent cave shell geometry. | delete/repurpose | Remove geometry authority. Keep only decoration helpers that attach to sampled volume surfaces. | 4 |
| `scripts/CaveInteriorBuilder.gd` | `cave_mouth_*` helpers tune mouth shape separately from terrain volume. | delete | Mouth shape must emerge from cave biome/density fields and shared meshing, not a builder-specific mouth path. | 4 |
| `scripts/testing/CaveGenerationTestRunner.gd` | Tests call `StructureSystem.cave_plan_for_region/build_cave`, inspect `height_edits`, `terrain_material_override_for_cell`, hidden portal cells, and base height helpers. | replace | Tests must prove cave biome samples exist before decoration and fail on hidden quads, material overrides, terrain edits, and StructureSystem cave authority. | 6 |
| `scripts/testing/CaveVisualPlaytestRunner.gd` | Visual runner still builds caves through `StructureSystem`, evaluates `cave_terrain_mouth_summary`, `hiddenPortalCells`, `stoneOverridePortalCells`, and `(x,z)` height helpers. | replace | Headed visual acceptance must inspect the shared volume mesh and fail on blocked/walled-off entrances, broken tops, hidden-quad dependency, and inserted portal look. | 6 |
| `scripts/PlaytestRunner.gd` | Cave smoke coverage still calls `StructureSystem.build_cave`, cave records, terrain openings, and hidden/override metadata. | replace | Broad playtest should consume cave-biome discovery, not create caves as structures. | 6 |
| `scripts/MainSaveState.gd` | Saves `height_edits` as terrain authority. | temporary adapter | Migrate terrain edits to deterministic 3D volume edit snapshots with additive save compatibility. | 1, 5 |
| `scripts/MainCore.gd` | Owns `height_edits` dictionary. | temporary adapter | Replace with volume edit storage. Height edits may be read only for migration. | 1, 5 |
| `scripts/HostileSystem.gd`, `scripts/NpcSystem.gd`, `scripts/npc_ai/**`, `scripts/story/**`, `scripts/visual/**`, tutorial/testing runners | Many gameplay systems still query `height_at_world`, `terrain_height_cell`, or `biome_at_cell`. | temporary adapter | Convert to 3D ground probes and world samples after the shared volume sampler/mesher exists. These are not cave-specific, but they are part of removing global `(x,z)` generation dependence. | 5 |

## Allowed Temporarily

Chunk and region keys may remain two-dimensional only when they are indexing/streaming coordinates. Examples: `cx/cz` chunk IDs, region loops, save keys, and broad activation ranges. They must not decide terrain height, cave air, material, biome, collision, or navigability.

Projection helpers may exist only when explicitly named as projections from a 3D sample. They must not become generation authority.

## Static Gate

`tools/run-true-3d-cave-biome-audit.ps1` is the static architecture audit. It must pass in the migrated worktree and must fail if banned cave-placement, hidden-quad, material-override, shell-geometry, height-edit, or non-adapter `(x,z)` generation authority returns.

This audit is not gameplay acceptance evidence. It does not prove caves are visually correct or passable. It prevents the known banned architecture from being silently accepted; cave success still requires contract tests plus headed visual screenshot inspection.
