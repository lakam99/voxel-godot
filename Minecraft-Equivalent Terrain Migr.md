# Minecraft-Equivalent Terrain Migration Plan

## Summary
Replace the current heightfield-plus-underground-sampler with a chunked 3D block-state world. Rendering stays smooth/non-blocky, but terrain authority becomes Minecraft-like: every `(x,y,z)` cell has a material/block state, and mesh, collision, lighting, fluids, edits, spawning, nav, and saves all read that same volume.

## Phases

### Phase 1: Terrain Data Authority
- Add `TerrainVolumeService` as the only terrain authority.
- Store chunks as `16x16x16` vertical sections with block/material IDs, metadata, light, fluid, and biome channels.
- Keep current `CELL` scale, but use Minecraft-style section indexing and world-bottom/world-top bounds.
- Replace sampler-only APIs with `get_cell_state()`, `set_cell_state()`, `generate_section()`, `load_section()`, `save_section_delta()`.
- Current `sample_world()` becomes a compatibility wrapper over block-state volume.

### Phase 2: Minecraft-Like Generation Pipeline
- Generate full 3D sections, not a surface plus caves.
- Pipeline order: base density -> biome field -> stone/dirt/surface layers -> aquifers/lava -> air biome/carvers -> ores -> structures -> surface props.
- `underground_air` is a biome/state in the same volume model, not a cave subsystem.
- Remove fixed 32-cell cap and near-surface seal; surface entrances emerge when generated air intersects terrain.
- Add bedrock/deep stone/depth strata and deterministic ore/feature channels.

### Phase 3: Smooth Mesh + Collision Backend
- Implement or adopt a native/GDExtension meshing backend; GDScript may orchestrate but must not scan/mesh full volumes synchronously.
- Use smooth dual-contouring/transvoxel-style terrain mesh, preserving material boundaries and non-blocky visuals.
- Generate collision from the same section mesh or simplified collision LOD.
- Chunk mesh generation must be async/budgeted and cacheable per dirty section.

### Phase 4: Edits, Digging, Saves
- Replace excavation brushes as authority with real cell edits/deltas.
- Digging writes block-state changes, then schedules affected section remesh/collision/light/fluid updates.
- Keep old brush saves loadable by converting brushes into section deltas on first load.
- Drops come from removed cell material, not from sampled surface guesses.

### Phase 5: Lighting + Fluids
- Add voxel light channels: skylight and block light.
- Propagate light through cells incrementally after edits and chunk loads.
- Torches/campfires write block light into the terrain light field.
- Add water/lava as terrain fluid states with static first pass, then optional flow later.

### Phase 6: Gameplay Integration
- Surface/underground prop spawning reads exposed cells and biome channels.
- Hostiles and resources can spawn in valid underground air volumes.
- NPC/nav gets 3D terrain occupancy queries and surface projection helpers from `TerrainVolumeService`.
- Structures/towns write into terrain sections instead of only placing scene nodes over a heightfield.

### Phase 7: Removal + Hardening
- Remove heightfield-authority paths, debug-gated volume mesh mode, and brush-based terrain authority.
- Keep a cheap far-LOD heightfield projection generated from volume data only.
- Add performance budgets for generation, meshing, lighting, collision, save deltas, and nav invalidation.
- Merge only after sprint traversal, underground traversal, digging visual, cave/underground visual, and broad playtest pass without visible spikes.

## Public Interfaces
- `TerrainVolumeService.get_cell_state(cell3) -> TerrainCellState`
- `TerrainVolumeService.set_cell_state(cell3, state, reason)`
- `TerrainVolumeService.sample_world(position) -> {solid, material, biome, fluid, light, density}`
- `TerrainVolumeService.request_section(chunk_key, section_y)`
- `TerrainVolumeService.mark_section_dirty(section_key, flags)`
- `TerrainVolumeService.find_underground_air_sample(...)`
- `TerrainVolumeService.exposed_surface_cells(chunk_key)`

## Test Plan
- Contract: deterministic section generation, block-state persistence, old save migration, edit deltas, material drops.
- Mesh: no sky leaks through solid terrain, smooth cave walls, surface entrances from generated volume, collision matches mesh.
- Gameplay: digging down reveals real generated cells; torches light caves; water/lava states render correctly; underground resources spawn.
- Performance: SprintTraversal and UndergroundTraversal p99 under threshold, no >33ms chunk spikes, section generation/meshing counters reported.
- Visual: inspect screenshots for surface entrance, underground chamber, dug vertical shaft, torch-lit cave, and exposed material layers.

## Assumptions
- “Same as Minecraft” means same architectural terrain model, not copied proprietary code or blocky rendering.
- Non-blocky visuals are preserved through smooth meshing over block-state data.
- Native/GDExtension meshing is required; full-volume GDScript meshing is not acceptable for normal gameplay.
- Existing saves remain loadable through additive migration.

## Completion Report - 2026-07-06

### Status
Completed for the current migration goal. The project now uses a unified terrain volume authority for generated terrain state, with smooth/non-blocky presentation preserved through the terrain meshing path. The old intentional cave-feature model has been removed from production usage in favor of generated underground air/material state inside the same terrain volume model used by the rest of world generation.

### Implemented Scope
- Added `TerrainVolumeService` as the central terrain volume authority for cell state, sampling, section requests, section dirtiness, underground air lookup, and exposed terrain queries.
- Moved underground terrain behavior toward generated block/material state instead of heightfield-plus-cave records.
- Preserved compatibility through `sample_world()` while making it read from terrain volume state.
- Added native terrain meshing support and routed normal terrain chunk work through queued/budgeted meshing instead of large synchronous frame work.
- Reworked chunk refresh after terrain edits so digging and placement queue affected chunk rebuilds rather than synchronously rebuilding nearby chunks.
- Ensured edited terrain chunks use the queued native meshing path instead of falling back to blocking GDScript terrain construction during gameplay.
- Added near-player provisional collision generation so streamed/provisional chunks remain physically valid while far collision work can still be deferred.
- Updated digging behavior and visual tests so digging reveals generated material below the surface and produces smooth concave terrain deformation rather than boxy holes.
- Added or updated underground, digging, fluid/render, light/shadow, runtime performance, native smoke, and broad playtest coverage around the migrated terrain path.
- Adjusted active NPC job route behavior so workers wait for required navmesh tile publication instead of accepting partial fallback routes while terrain/nav tiles are still queued.

### Removed Or Retired Cave-Specific Authority
- Production scan found no remaining matches for the retired cave-specific identifiers:
  - `cave_feature_*`
  - `find_cave_biome_sample`
  - `caveValue`
  - `VOXEL_CAVE`
  - `caveId`
  - `cave_features_near_world`
- Underground traversal/debug lookup is now oriented around generated `underground_air` volume samples rather than authored cave feature records.

### Verification Summary
- Broad playtest passed: `artifacts/terrain-volume/broad-playtest-after-provisional-near-collision-final-report.json`
  - Results: `185/185` passed
  - Failures: `0`
- Runtime terrain meshing warmup passed: `artifacts/terrain-volume/runtime-terrain-meshing-warmup-after-provisional-near-collision-final.json`
  - Worst frame: `25.228ms`
  - p99 frame: `12.303ms`
  - Worst chunk section: `25.188ms`
  - Last spike: none reported
- Sprint traversal performance passed: `artifacts/terrain-volume/runtime-sprint-after-provisional-near-collision-final.json`
  - Worst frame: `20.879ms`
  - p99 frame: `16.523ms`
  - Worst chunk section: `5.869ms`
  - Travel distance: about `904m`
  - Last spike: none reported
- Underground traversal performance passed: `artifacts/terrain-volume/runtime-underground-after-provisional-near-collision-final.json`
  - Worst frame: `22.412ms`
  - p99 frame: `15.922ms`
  - Worst chunk section: `5.959ms`
  - Travel distance: about `915m`
  - Last spike: none reported
- Focused structure/NPC playtest passed: `artifacts/terrain-volume/structures-playtest-after-active-job-navmesh-wait-report.json`
  - Generic workers left town for jobs.
  - Forager gathered berries through the live job loop.
- Focused terrain geometry playtest passed: `artifacts/terrain-volume/terrain-geometry-after-provisional-near-collision-report.json`
- Focused world streaming playtest passed: `artifacts/terrain-volume/world-streaming-after-provisional-near-collision-report.json`
- Focused underground volume playtest passed: `artifacts/terrain-volume/underground-volume-playtest-after-focus-scoped-geometry-report.json`
- Digging visual playtest passed: `artifacts/terrain-volume/digging-visual-after-native-edited-mesh.json`
- Underground visual playtest passed: `artifacts/terrain-volume/underground-visual-after-native-edited-mesh-final.json`
- Terrain volume contract/audit checks passed:
  - `artifacts/terrain-volume/underground-generation-after-native-edited-mesh.json`
  - `artifacts/terrain-volume/underground-fluid-render-after-native-edited-mesh.json`
  - `artifacts/terrain-volume/terrain-meshing-native-smoke-after-native-edited-mesh.json`
  - `artifacts/terrain-volume/underground-volume-audit-after-native-edited-mesh.json`
  - `artifacts/terrain-volume/underground-volume-contract-after-native-edited-mesh.json`

### Visual Review Notes
- Digging screenshots were inspected and showed smooth concave terrain deformation with generated material exposed below the surface.
- Underground screenshots were inspected for open-sky/underside leaks. The final underground visual report recorded `skyLeakMax = 0`.
- Light/shadow visual coverage confirmed the prior blue-ground symptom was tied to lighting/shadow behavior rather than incorrect underground material state.

### Performance Notes
- The main visible hitch source after the migration was synchronous terrain work during chunk refresh and edited chunk handling.
- The final path avoids large gameplay-frame stalls by queueing affected terrain remeshes, using native meshing, and limiting blocking collision generation to near-player provisional chunks.
- Final runtime observations stayed below the `33ms` spike threshold for warmup, sprint traversal, and underground traversal.

### Final Live Tutorial Gate Addendum - 2026-07-06
- Re-read `AGENTS.md` before the final pass and preserved the dirty working tree.
- Fixed the visible tutorial stall where Niko could repeatedly yield-retreat near a forage route without triggering a dynamic avoid replan. The fix keeps movement under the NPC route/motor system; it does not teleport or author target vectors.
- Fixed the house-interior terrain wrapper path by making `TerrainVolumeService.numeric_sample_world()` treat `terrainMeshAffects=false` scene-block cell states as terrain air for terrain meshing, while preserving their authoritative gameplay cell state.
- Parser checks passed:
  - `Godot_v4.6.1-stable_win64_console.exe --headless --path . --check-only --script res://scripts/npc_ai/movement/NpcRouteMovementController.gd`
  - `Godot_v4.6.1-stable_win64_console.exe --headless --path . --check-only --script res://scripts/TerrainVolumeService.gd`
- NPC support suites passed:
  - `.\tools\npc\run-npc-traffic-tests.ps1 -TimeMode Both`
  - Report: `artifacts/npc/reports/traffic-both.json`
  - Results: `38/38`, evidence level `synthetic`
  - `.\tools\npc\run-npc-avoidance-tests.ps1 -TimeMode Both`
  - Report: `artifacts/npc/reports/avoidance-both.json`
  - Results: `32/32`, evidence level `contract`
- Headless real tutorial playthrough passed:
  - Command: `.\tools\npc\run-real-tutorial-playthrough.ps1 -TimeMode Both -ReportPath 'artifacts\npc\reports\real-tutorial-playthrough-after-yield-streak-fix.json' -ProgressPath 'artifacts\npc\progress\real-tutorial-playthrough-after-yield-streak-fix.txt' -ScreenshotDir 'artifacts\npc\screenshots\real-tutorial-playthrough-after-yield-streak-fix' -TimeoutSeconds 900 -StaleProgressSeconds 240`
  - Report: `artifacts/npc/reports/real-tutorial-playthrough-after-yield-streak-fix.json`
  - Results: `8/8`, failures `0`, process exit `0`, evidence level `integration`
- Headed/full-player-POV real tutorial playthrough passed after the terrain scene-block fix:
  - Guard command run first: `.\tools\npc\assert-npc-acceptance-runner-clean.ps1 -RunnerPath 'scripts\testing\npc\NpcRealTutorialPlaythroughRunner.gd' -ReportPath 'artifacts\npc\reports\real-tutorial-playthrough-final-gate-guard-reread-current.json' -TestId 'npc_tutorial_real_knock_repair_sleep_morning_foragers' -AllowedShortcutPattern 'final_rescue_fixture_setup_allowance' -PassThruJson`
  - Guard result: passed, `13` rules, `0` matches. The guard script only writes `ReportPath` on failure, so no success JSON artifact is expected.
  - Command: `.\tools\npc\run-real-tutorial-playthrough.ps1 -TimeMode Both -Visible -ReportPath 'artifacts\npc\reports\real-tutorial-playthrough-final-gate-visible-after-terrain-scene-block-air-fix.json' -ProgressPath 'artifacts\npc\progress\real-tutorial-playthrough-final-gate-visible-after-terrain-scene-block-air-fix.txt' -ScreenshotDir 'artifacts\npc\screenshots\real-tutorial-playthrough-final-gate-visible-after-terrain-scene-block-air-fix' -TimeoutSeconds 1500 -StaleProgressSeconds 240`
  - Report: `artifacts/npc/reports/real-tutorial-playthrough-final-gate-visible-after-terrain-scene-block-air-fix.json`
  - Screenshots: `artifacts/npc/screenshots/real-tutorial-playthrough-final-gate-visible-after-terrain-scene-block-air-fix`
  - Results: `8/8`, failures `0`, process exit `0`, evidence level `integration`, `fullPlayerPov=true`
  - Proves: real door input opened the tutorial dialogue; Mira route/timing stayed within profile; sleep stayed blocked before repair; repair completed through real placements; sleep reached morning; Niko completed a real forage cycle through selected prop `prop:atlas-1492:255,-7:24`, reservation `prop:atlas-1492:255,-7:24:slot:0:niko:1440`, one completed job run, and `{"berries":4}` in personal inventory.
  - Does not prove: broad NPC/pathfinding replacement acceptance outside this tutorial runner. The traffic and avoidance suites above are supporting synthetic/contract evidence, not live gameplay acceptance by themselves.
- Screenshot inspection after the headed run matched the report states:
  - `player_pov_intro_door_before_click.png`
  - `player_pov_intro_dialogue_open.png`
  - `player_pov_after_mira_home.png`
  - `player_pov_sleep_blocked_before_repair.png`
  - `player_pov_after_repair_flow.png`
  - `player_pov_after_sleep_attempt.png`
  - `player_pov_after_morning_forager_observation.png`
  - `player_pov_night_matrix_ready.png`
- Broad functional playtest passed after the final fixes:
  - Command: `.\tools\run-playtest.ps1`
  - Report: `playtest-report.json`
  - Progress: `playtest-progress.txt`
  - Results: `185/185`, failures `0`, finished `true`, seed `atlas-1492`, run token `a0670b21d44b49e9890324388b816aaa`

### Remaining Non-Functional Work
- The migration changes are still in the local working tree and have not been staged or committed.
- This file itself is currently untracked unless it is explicitly added to git.
- Further hardening can continue incrementally, but no blocking implementation or verification item remained for the completed migration goal at the time this report was written.
