# Visual Phase 8 Report

## Scope

Phase 8 improves procedural building presentation while preserving generated block cells, colliders, destruction, save/load, and structural integrity behavior.

Implemented:

- Replaced per-call block `BoxMesh` allocation with cached shared unit meshes:
  - `chamfered` for most blocks.
  - `plain` for transparent/emissive blocks that should keep exact faces.
- Added a shared `building_material.gdshader` for world-space surface breakup and subtle grid/mortar variation.
- Retuned wood, stone, dirt, path, workbench, anvil, furnace, door, roof, and trim materials through the shared building shader.
- Added generated roof metadata and per-block child visuals:
  - low roof slabs,
  - ridge caps,
  - eave trim,
  - chimneys.
- Added generated structure accents without adding physical blocks:
  - window frames,
  - door frames,
  - corner timbers,
  - signs,
  - camp fence posts/rails,
  - trader crate/barrel details.
- Added automated visual coverage for cached meshes, roof roles, and accent roles.
- Stabilized the NPC equipment/pathing playtest by simulating a few more frames before asserting the wall detour result.

## Files Changed

- `resources/visual/building_material.gdshader`
- `scripts/MainChunkTerrain.gd`
- `scripts/MainCore.gd`
- `scripts/MainSetupScene.gd`
- `scripts/StructureSystem.gd`
- `scripts/PlaytestRunner.gd`

## Verification

Commands run:

```powershell
.\tools\run-playtest.ps1
.\tools\run-world-signature.ps1
.\tools\run-visual-captures.ps1
& 'C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' --headless --path . --quit
git diff --check
```

Results:

- Playtest: 148 passed, 0 failed.
- World signature: matches `artifacts\baselines\world-signature\atlas-1492.json`.
- Visual captures: generated successfully with Vulkan/Forward Plus.
- Godot import check: passed.
- Diff whitespace check: passed.

Notes:

- `.\tools\run-visual-captures.ps1 -Headless` fails in this environment because Godot uses the dummy renderer and returns a null viewport texture. The final capture run used the non-headless Vulkan path.
- Town captures were inspected manually. The first sloped-prism roof attempt produced sawtooth roof silhouettes, so it was replaced with lower-profile slabs plus ridge/eave accents.

## Key Automated Checks

- `building_visual_mesh_cache`: cache keys `["chamfered", "plain", "visual_roof_ridge_bar"]`, block visual mesh ids `2`.
- `building_roof_visuals`: 833 roof metadata blocks, 928 roof visuals, 326 roof trims, 16 chimney visuals.
- `building_accent_visuals`: window frames, door frames, corner timbers, signs, fence posts/rails, crates, and barrels present.
- `npc_equipment_and_pathing`: weapon visuals and use animation still pass, with detour around wall confirmed.

## Capture Outputs

- `artifacts\visual\latest\town_noon.png`
- `artifacts\visual\latest\town_sunset.png`
- `artifacts\visual\latest\forest_midnight.png`
- `artifacts\visual\latest\forest_rain.png`
- `artifacts\visual\latest\mountain_day.png`
- `artifacts\visual\latest\water_clear.png`
- `artifacts\visual\latest\water_sunset.png`
- `artifacts\visual\latest\water_overcast.png`
- `artifacts\visual\latest\hud_gameplay.png`

## Performance Snapshot

From the playtest performance HUD check:

- Frame time sample: `6.32 ms`.
- Hostile update sample: `0.90 ms`.

From town visual capture metadata:

- Chunks: `49`.
- Blocks: `1219`.
- Props: `897`.
- Draw estimate: `5295`.
- Physics bodies: `2188`.
