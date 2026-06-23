# Visual Phase 3 Report

Phase 3 replaces the plain terrain material with a stylized shader and repairs chunk-edge terrain normals. It preserves terrain heights, gameplay cells, triangle topology, collision generation, water, props, structures, weather geometry, characters, and UI.

## Added

- `shaders/stylized_terrain.gdshader`
- `resources/visual/terrain_material.tres`
- `artifacts/baselines/visual/phase3/`

The Phase 3 capture set and contact sheet are committed under:

- `artifacts/baselines/visual/phase3/*.png`
- `artifacts/baselines/visual/phase3/*.json`
- `artifacts/baselines/visual/phase3/phase3-contact-sheet.png`

Before captures remain in:

- `artifacts/baselines/visual/phase2/`

## Terrain Changes

- `build_chunk_mesh()` now samples a one-cell height border outside each chunk before emitting vertices.
- Top terrain vertices receive explicit smooth normals from neighboring height samples.
- Chunk skirts keep the existing emitted positions and triangle order, with intentional outward normals.
- `SurfaceTool.generate_normals()` is no longer used for terrain chunks.
- The terrain material is loaded from `resources/visual/terrain_material.tres`, with the old vertex-color `StandardMaterial3D` kept as a fallback.

The topology contract is unchanged:

- Expected vertices per chunk: `5376`
- Formula: `28 * 28 * 6 + 28 * 4 * 6`
- Collision still uses the same terrain mesh path through `mesh.create_trimesh_shape()`.

## Shader Changes

The terrain shader keeps the existing `BIOME_COLORS` vertex colors as its palette base, then adds:

- world-space macro color breakup
- slope-based rock tinting
- altitude-aware snow/pale-rock tinting
- subtle top-versus-side value shaping
- high roughness and restrained specular response
- a small stylized fill term so terrain remains readable under heavy shadow

The shader stays procedural and palette-controlled. No photorealistic textures or new runtime art dependencies were added.

## Visual Review

Contact sheet:

```text
artifacts/baselines/visual/phase3/phase3-contact-sheet.png
```

Observed changes:

- `town_noon` and `hud_gameplay`: town terrain now has soft material variation while remaining readable under building shadows.
- `town_sunset`: terrain keeps the warm Phase 2 atmosphere with less flat vertex-color response.
- `forest_midnight`: night terrain remains visible and does not lose the cozy readable floor.
- `forest_rain` and `water_overcast`: rain scenes retain their cool weather tone with better ground form.
- `mountain_day`: the close terrain capture is smoother and less visibly striped.

## Verification

Pre-edit playtest command:

```powershell
.\tools\run-playtest.ps1
```

Pre-edit result:

- Passed: `true`
- Result count: `138`
- Shell wall time: approximately `117.7` seconds
- `performance_playtest_debug_hud`: frame `4.66`, hostiles `0.53`, HUD refresh keys `8`

Post-edit playtest command:

```powershell
.\tools\run-playtest.ps1
```

Post-edit result:

- Passed: `true`
- Result count: `141`
- Shell wall time: approximately `113.3` seconds
- `performance_playtest_debug_hud`: frame `3.80`, hostiles `0.50`, HUD refresh keys `8`

New or relevant assertions:

- `terrain_collision_shapes`: `49/49` chunks with shapes
- `terrain_mesh_topology_signature`: `49/49` chunks match `5376` vertices, normals `49/49`
- `terrain_shader_material`: `res://shaders/stylized_terrain.gdshader` assigned `49/49`
- `terrain_chunk_edge_normals`: `16` pairs, `464` comparisons, max edge normal delta `0.0000` degrees
- `terrain_generation_profile`: normal `3374`, average variation `0.73`, smooth `87%`, mountain samples `2`, max `68.96`
- Movement/collision assertions still pass, including descent smoothing, ascent smoothing, steep ascent blocking, jump, and cobblestone path walking.

World signature command:

```powershell
.\tools\run-world-signature.ps1
```

Result:

- World signature matched `artifacts/baselines/world-signature/atlas-1492.json`.

Visual capture command:

```powershell
.\tools\run-visual-captures.ps1
```

Result:

- Generated `7` standard PNG captures.
- Generated `7` per-case metadata files.
- Generated `1` aggregate `visual-captures.json`.

## Capture Metadata Stability

Phase 2 and Phase 3 capture metadata kept the same gameplay-relevant counts:

| Case | Draw Estimate | Physics Bodies | Props | Blocks | Chunks |
|---|---:|---:|---:|---:|---:|
| `town_noon` | `6504 -> 6504` | `2188 -> 2188` | `897 -> 897` | `1219 -> 1219` | `49 -> 49` |
| `town_sunset` | `6504 -> 6504` | `2188 -> 2188` | `897 -> 897` | `1219 -> 1219` | `49 -> 49` |
| `forest_midnight` | `6697 -> 6697` | `2242 -> 2242` | `954 -> 954` | `1216 -> 1216` | `49 -> 49` |
| `forest_rain` | `6538 -> 6538` | `2242 -> 2242` | `954 -> 954` | `1216 -> 1216` | `49 -> 49` |
| `mountain_day` | `7276 -> 7276` | `2294 -> 2294` | `1006 -> 1006` | `1216 -> 1216` | `49 -> 49` |
| `water_overcast` | `6738 -> 6738` | `2250 -> 2250` | `956 -> 956` | `1222 -> 1222` | `49 -> 49` |
| `hud_gameplay` | `6504 -> 6504` | `2188 -> 2188` | `897 -> 897` | `1219 -> 1219` | `49 -> 49` |

## Performance Notes

The Phase 3 shader adds material math but does not add meshes, draw calls, props, blocks, collision bodies, or chunk work in the visual capture scenes. The post-edit playtest frame debug value improved versus the same-session pre-edit run, which is within expected run-to-run variance and does not indicate a regression.

## Scope Notes

- No water, weather, prop, structure, NPC, input, inventory, UI, save, or procedural generation behavior was intentionally changed.
- `scripts/visual/TerrainMaterialFactory.gd` was not added because the material is static and can be loaded directly.
- The Phase 4 water/weather work has not been started.
