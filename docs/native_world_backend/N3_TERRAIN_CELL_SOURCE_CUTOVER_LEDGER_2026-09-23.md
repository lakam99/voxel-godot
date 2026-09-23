# N3 terrain cell-source vertical slice and caller ledger

Status: service-level native read path implemented; production `WorldGenerationSystem`
and `TerrainVolumeService` are **not** cut over. No legacy path is deleted yet.

The inert `NativeTerrainRuntimeOwner` now accepts bounded, typed durable cell
transactions against its current native revision. It checks source identity,
rejects stale edits, and returns the existing edit republication plan with
`physicalReady: false`. The same owner subsequently reads the edited cell and
exports its v2 save volume; clearing the edit uses the same native authority.
The installed-engine service contract passes at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790171666415-c810bcff/report.json`.
This is not wired to gameplay edits or physical replacement, and does not
establish New Game/Continue or normal-game acceptance.

Follow-up edit sequencing gate: a committed edit is retained as a pending
physical barrier. The owner preflights the bounded republication footprint
before committing, verifies the native affected-section receipt, and informs
the block publisher immediately after commit. A second edit returns pending
without advancing the native save revision. There is intentionally no barrier
release method yet: the owner remains fail-closed after one edit until N5 can
provide exact live collision acknowledgement, occupancy safety, and a
revision-bound release contract. This service component is not suitable for
production edits in its present state. Focused evidence:
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790172076190-ccda949c/report.json`.
The receipt guard now requires exact deduplicated set equality between the
native conservative affected sections and the preflighted mesh halo. The
focused real receipt plus forged foreign, duplicate, and missing-section
checks pass at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790172197383-6f38d9b7/report.json`.
The stronger missing-neighbor check passes at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790172570225-d0c9c2f2/report.json`
in the isolated N3 worktree.
Release-candidate inspection now binds the pending plan to the live owner
instance, source identity/epoch, native revision and barrier identity before
checking all subwindow/mesh receipts. Forged owner, stale revision, foreign
epoch, partial and duplicate candidates are covered by the installed-engine
service fixture at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790172721925-a15dd1ec/report.json`.
Even a structurally complete candidate returns
`production_physical_owner_unbound`: caller dictionaries cannot attest to live
collision or actor occupancy, and this method never clears the barrier.

`NativeTerrainOccupancySource` now derives `terrain_occupancy_at_cell`'s
ten gameplay fields from one native three-cell batch (center, above, below).
The owner exposes the typed result with pending/revision propagation. The
installed-engine service fixture first compared a saved edited stone cell and
saved air over support, then independently compared a generated same-seed
neighbor triple after initializing the real `WorldGenerationSystem` sampler.
All comparisons passed at
`artifacts/native-world-backend/n3-terrain-runtime-owner-1790173005001-accdc039/report.json`.
An earlier fixture run initialized `TerrainVolumeService` with no generator;
its unedited neighbors returned air and were not a valid generated parity
oracle. Production `WorldGenerationSystem.terrain_occupancy_at_cell` and nav
consumers still use the script service; this bridge supplies source facts only
and does not prove physical publication or safe navigation occupancy.
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
