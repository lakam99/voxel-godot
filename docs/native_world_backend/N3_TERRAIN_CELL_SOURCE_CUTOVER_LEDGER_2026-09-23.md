# N3 terrain cell-source vertical slice and caller ledger

Status: service-level native read path implemented; production `WorldGenerationSystem`
and `TerrainVolumeService` are **not** cut over. No legacy path is deleted yet.

`NativeTerrainCellSource.read_cells` is a bounded, all-or-nothing gameplay-cell
query over `NativeWorldBackend.pin_effective_page` and
`NativeEffectiveTerrainPage.sample_batch`. It retains caller order and
duplicates, groups by 280-cell source page, maps the native cell-center record
to the existing cell-state vocabulary, and rejects absent owner, pending or
failed page, incomplete result, mixed source identity, and delta revision
change during the read. It has no GDScript generation or saved-edit fallback.
The exact edited-air, edited-stone, cross-page, light/metadata, and
post-commit fresh-pin contract passes at
`artifacts/native-world-backend/n3-terrain-cell-source-1790169372413-f9b5e411/report.json`.
This does not establish generated-cell parity, normal-game latency, live
collision, visual behavior, or N3 production authority.

`NativeTerrainNumericSource.read_numeric_batch` is the next source slice. A
mixed batch pins pages once per page and requests `worldNumeric` with
`terrain_mesh` intent and `surfaceProjectionNumeric` with
`terrain_collision` intent, both semantic revision 1. It rejects page
pending/failure, mixed source identity, incomplete/misordered results, and
delta or shaping revision changes without returning partial rows. The
focused installed-adapter test compares exact Godot `Vector3` values with
`TerrainVolumeService.numeric_sample_world` and
`WorldGenerationSystem.volume_surface_numeric_sample_at_grid_cell` at
positive and negative coordinates, including a negative durable-air edit in
both channels. Its contract passes at
`artifacts/native-world-backend/n3-terrain-numeric-source-1790169978387-9adf2694/report.json`.
The mock pending/failure cases are service-level propagation checks. This
numeric projection is **not** the higher-level walkable-surface/occupancy
projection and does not prove engine collision or nav readiness.

## Production caller/deletion map

| Existing API/owner | Observed production consumers | Native cutover requirement |
| --- | --- | --- |
| `TerrainVolumeService.get_cell_state` via `WorldGenerationSystem.get_cell_state` | `SubsurfaceSystem` material/drop scan; `MainChunkTerrain` scene-block placement/removal; `WorldGenerationSystem` occupancy/other derived queries | Replace computational cell lookup with native gameplay cell-center batch. Keep gameplay callers and typed state vocabulary. Do not return a guessed generated cell while a page is pending. |
| `sample_world`, `sample_cell`, density/solid/material/biome wrappers | `HostileSystem`, `MainGameLoop`, `MainPlaytestTools`; many internal `WorldGenerationSystem` consumers | Native world-numeric query must preserve position-intent semantics, full sample dictionary, and pending state. The new cell facade alone is not a substitute. Remove `generate_sample_without_volume` fallback only at atomic cutover. |
| `numeric_sample_world`, `volume_surface_numeric_sample_at_grid_cell`, meshing payload and bounds | `VoxelTerrainRuntime`, `MainPlaytestTools`, terrain/fluid meshing services | `NativeTerrainNumericSource` now covers the first two numeric queries with exact native intent and pinned revision. It does not replace bulk meshing payload construction, bounds scans, or native block publication. Preserve render/collision halo. |
| `terrain_occupancy_at_cell`, `surface_projection_for_cell`, walkability and related surface queries | `MainPropFactory`, `StructureSystem`, `NpcSystem`, `GeneratedWorldNavigationAdapter`, `MainPlaytestTools`, `VoxelTerrainRuntime` | Derive from one native snapshot with explicit pending/physical publication. Do not change NPC/navigation consumers independently or infer collision readiness from a cell query. |
| `set_cell_state`, clear, box/sphere/deformation and incremental edits | `SubsurfaceSystem` digging, `MainChunkTerrain` scene blocks, `MainSaveState` legacy volume restore, `WorldGenerationSystem` brush conversion | Replace `TerrainVolumeService.edited_cells` composition with typed native transactions. Keep incremental gameplay budgeting, exact changed cells, drops, light followups, and actor-safe physical replacement. Scene overlays are a distinct non-mesh namespace. |
| `save_terrain_volume_deltas`, `load_terrain_volume_deltas`, section delta/revision | `MainSaveState` New Game/Continue, `SubsurfaceSystem` authority check, `VoxelTerrainRuntime` edit discovery, terrain/fluid publication | Preserve v2 envelope and pin one native revision for export/import. Delete full script snapshot/`edited_cells` scan only after native edit, save and publisher receipts are connected. Never persist Voxel Tools injected blocks as generated world deltas. |
| Light/fluid source and dirty-section APIs | `WorldGenerationSystem`, `VoxelTerrainRuntime` and gameplay lighting/fluid consumers | Retain orchestration where appropriate, but move canonical light/fluid source facts and delta invalidation to native before declaring N3 complete. |

The caller audit used `rg` across production `scripts/*.gd` (excluding
`scripts/testing/**`), then inspected `WorldGenerationSystem`'s public
forwarders and `TerrainVolumeService`'s owner methods. `NpcNavigationTestRunner`
is a test entry point, not production gameplay. The table is a cutover checklist,
not permission to delete a mixed-responsibility file. No code in NPC/nav was
changed. Next vertical slices should add bulk/derived queries and
transaction/save orchestration, before atomically replacing the
production `WorldGenerationSystem` forwarding paths.
