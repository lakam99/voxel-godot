# Visual Phase 7 Report

## Summary

Phase 7 upgrades small biome detail visuals while preserving the existing per-chunk `MultiMeshInstance3D` batching.

The old tiny boxes, cylinders, and spheres are replaced with cached low-poly `ArrayMesh` clusters for grass, flowers, reeds, pebbles, snow clumps, scrub, and leaf litter. Detail placement rules, density, RNG flow, chunk ownership, and collision behavior remain unchanged.

## Added Files

- `resources/visual/detail_material.gdshader`

## Changed Files

- `scripts/MainPlaytestTools.gd`
- `scripts/MainSetupScene.gd`
- `scripts/PlaytestRunner.gd`

## Detail Mesh Library

`detail_mesh()` now builds and caches reusable low-poly meshes:

- `grass`: multi-blade grass cluster.
- `flowerStem`: complete flower variant with stem, leaves, and petal surface.
- `flowerBloom`: second complete flower variant with a different petal count/shape.
- `reed`: taller clustered reed stems and blades.
- `pebble`: faceted small stone cluster.
- `snowClump`: grouped low snow mounds.
- `scrub`: dry blade/twig cluster for desert and savanna.
- `leafLitter`: several flat leaf diamonds on the ground.

The legacy `flowerStem` and `flowerBloom` batch names are kept so the existing flower placement path still emits the same number of batched transforms. The meshes themselves now contain complete flower geometry.

## Material And Batch Behavior

Detail materials now use `resources/visual/detail_material.gdshader`.

The shader provides:

- shared base colors per detail family,
- deterministic per-instance tint through `MultiMesh.use_colors`,
- deterministic wind phase through `MultiMesh.use_custom_data`,
- restrained vertex sway for grass, reeds, scrub, flowers, and leaf litter,
- no alpha blending.

Each detail batch now also sets a visibility range:

- grass and flowers: `64m`,
- reeds and scrub: `82m`,
- pebbles, snow clumps, and leaf litter: `58m`.

This keeps small ground clutter from rendering to the horizon.

## Determinism And Scope

This phase keeps `spawn_chunk_detail_batches()` and `MultiMeshInstance3D` as the foundation.

No gameplay colliders are added. The detail batches remain non-interactive decoration. No trees, rocks, forage props, wildlife, ore, structures, terrain generation, blocks, characters, HUD, inventory, combat, or weather placement logic were changed.

Biome detail placement rules and density are unchanged. Flower placement still consumes the same two RNG draws for yaw and scale, then emits two transforms as before.

The optional Blender bush variants are not integrated in this phase because current bush/forage gameplay props are separate interactive objects, not chunk detail batches.

## Visual Gate

Capture run:

```text
.\tools\run-visual-captures.ps1
```

Review notes:

- Forest rain: grass, flowers, leaf litter, and nearby pebbles read as clustered ground details rather than pins and marbles.
- Water clear: reeds and shore grass remain batched and more readable near water.
- Mountain day: distant small clutter remains controlled while generated trees and stones remain visible.

Capture performance metadata stayed at the same draw estimates as Phase 6:

| Case | Chunks | Props | Draw Estimate |
|---|---:|---:|---:|
| `town_noon` | 49 | 897 | 4779 |
| `forest_rain` | 49 | 954 | 4798 |
| `mountain_day` | 49 | 1006 | 5396 |
| `water_clear` | 49 | 941 | 4848 |

## Regression Verification

Commands run:

```text
.\tools\run-playtest.ps1
.\tools\run-world-signature.ps1
.\tools\run-visual-captures.ps1
git diff --check
```

Results:

- Playtest: `145/145` assertions passed.
- Chunk detail batch gate: `49/49` chunks with decor, `225` batches, `2873` instances, `0` colliders.
- Detail upgrade gate: `225/225` batches use `ArrayMesh`, instance colors, custom data, and visibility ranges.
- Detail types present: `grass`, `pebble`, `scrub`, `flowerStem`, `flowerBloom`, `leafLitter`, `reed`, `snowClump`.
- Performance HUD gate: frame `3.95`, hostiles `0.50`.
- Terrain topology gate: `49/49` chunks still match the terrain mesh signature.
- World signature: matched `artifacts/baselines/world-signature/atlas-1492.json`.
- Visual captures: 9 capture cases generated in `artifacts/visual/latest`.
- `git diff --check`: no whitespace errors.

Known warning:

- `run-playtest.ps1` exits successfully but still prints Godot's `ObjectDB instances leaked at exit` warning. This warning pre-existed Phase 7 and did not fail the regression gate.

## Scope Notes

- This phase intentionally does not alter generated tree or rock visuals from Phase 6.
- This phase intentionally does not replace interactive forage bushes or wildlife.
- This phase intentionally does not change terrain, structures, buildings, item meshes, UI, NPCs, combat, survival, save data, or procedural placement rules.
