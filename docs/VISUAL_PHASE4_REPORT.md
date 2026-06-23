# Visual Phase 4 Report

## Summary

Phase 4 replaces the flat transparent water material and the old sphere-based sky/weather presentation while preserving weather simulation and gameplay effects.

The pass adds a stylized water shader, shader-backed water material, low-poly cloud cards, and a batched star field. Rain and snow remain MultiMesh-based, the large water plane stays at the existing water level, and weather-driven wet/cold survival behavior is unchanged.

## Changed Files

- `shaders/stylized_water.gdshader`
- `resources/visual/water_material.tres`
- `shaders/stylized_clouds.gdshader`
- `resources/visual/cloud_material.tres`
- `scripts/MainSetupScene.gd`
- `scripts/MainGameLoop.gd`
- `scripts/WeatherSystem.gd`
- `scripts/PlaytestRunner.gd`
- `scripts/visual/VisualCaptureRunner.gd`
- `artifacts/baselines/visual/phase4/`

No Phase 5 Blender asset work was started.

## Water

The water plane remains one large `PlaneMesh` at `WATER_LEVEL` with the same 3000 by 3000 coverage. The mesh now uses `resources/visual/water_material.tres`, backed by `shaders/stylized_water.gdshader`.

The shader provides shallow/deep color variation, two slow procedural wave layers, restrained vertex motion, reduced glint, Fresnel alpha response, weather tinting, sunset tinting, and controlled transparency. `MainGameLoop.apply_weather_lighting()` now updates shader parameters for cloud cover, weather intensity, day factor, sunset warmth, and wave time instead of replacing albedo every frame. A StandardMaterial fallback is still present if the shader resource fails to load.

The standard capture set now includes `water_clear`, `water_sunset`, and `water_overcast`. These cases use a capture-only shallow pond fixture near the existing water playtest target so the visual baseline shows the water shader directly.

## Weather

`WeatherSystem` still owns weather state, biome profiles, precipitation behavior, and snapshot semantics. Snapshot fields used by existing systems are preserved:

- `kind`
- `cloudCover`
- `intensity`
- `waterInfluence`
- `rainVisible`
- `snowVisible`
- `starsVisible`
- `clouds`
- `stars`
- `particleQuality`

The snapshot also now reports presentation diagnostics:

- `cloudNodes`
- `starNodes`
- `batchedStars`
- `cloudCards`

Stars are now represented by one `MultiMeshInstance3D` while preserving the logical count of 160 stars in diagnostics. Clouds are now generated low-poly `ArrayMesh` cards using the shared cloud shader material instead of flattened sphere meshes. Rain and snow remain MultiMesh-based.

## Visual Review

Contact sheet:

`artifacts/baselines/visual/phase4/phase4-contact-sheet.png`

Phase 4 capture outputs:

- `town_noon`
- `town_sunset`
- `forest_midnight`
- `forest_rain`
- `mountain_day`
- `water_clear`
- `water_sunset`
- `water_overcast`
- `hud_gameplay`

Review notes:

- Water now reads as a visible stylized surface in clear, sunset, and overcast captures.
- Sunset water picks up warmer tinting without replacing the material.
- Cloud silhouettes are grouped and softer than the previous flattened spheres.
- Night stars remain logically present while no longer costing one node per star.
- Rain/snow visibility tests remain meaningful.

## Verification

Final commands run:

```text
.\tools\run-playtest.ps1
.\tools\run-world-signature.ps1
.\tools\run-visual-captures.ps1
```

Results:

- Playtest: `143/143` assertions passed.
- World signature: matched `artifacts/baselines/world-signature/atlas-1492.json`.
- Visual captures: 9 PNGs, 9 per-case JSON files, and `visual-captures.json` generated and copied into `artifacts/baselines/visual/phase4/`.

Key assertion details:

- `water_visual_material`: shader `res://shaders/stylized_water.gdshader`, water y `11.10`, plane `(3000.0, 3000.0)`, weather params `0.82/0.46`.
- `weather_presentation_batching`: stars batched `true`, star nodes `0/160`, cloud cards `18/18`, rain/snow MultiMeshes still present.
- `weather_visual_system`: rain `true`, snow `true`, stars `true`, clouds `18`, stars `160`.
- `survival_weather_warmth_drain`: plain `0.350`, wet+cold `0.780`, warmed `0.350`.
- `performance_playtest_debug_hud`: frame `3.89`, hostiles `0.48`.

## Relative Capture Metrics

Shared Phase 3 to Phase 4 capture metadata:

| Case | Draw Estimate | Physics Bodies | Props | Blocks |
|---|---:|---:|---:|---:|
| `town_noon` | 6504 -> 6504 | 2188 -> 2188 | 897 -> 897 | 1219 -> 1219 |
| `town_sunset` | 6504 -> 6504 | 2188 -> 2188 | 897 -> 897 | 1219 -> 1219 |
| `forest_midnight` | 6697 -> 6538 | 2242 -> 2242 | 954 -> 954 | 1216 -> 1216 |
| `forest_rain` | 6538 -> 6538 | 2242 -> 2242 | 954 -> 954 | 1216 -> 1216 |
| `mountain_day` | 7276 -> 7276 | 2294 -> 2294 | 1006 -> 1006 | 1216 -> 1216 |
| `water_overcast` | 6738 -> 6649 | 2250 -> 2237 | 956 -> 943 | 1222 -> 1222 |
| `hud_gameplay` | 6504 -> 6504 | 2188 -> 2188 | 897 -> 897 | 1219 -> 1219 |

New Phase 4 water captures:

| Case | Draw Estimate | Physics Bodies | Props | Blocks | Weather | Stars | Star Nodes | Clouds |
|---|---:|---:|---:|---:|---|---:|---:|---:|
| `water_clear` | 6653 | 2235 | 941 | 1222 | clear | 160 | 0 | 18 |
| `water_sunset` | 6638 | 2237 | 943 | 1222 | clear | 160 | 0 | 18 |

## Scope Notes

- Terrain geometry, generation signature, gameplay collision, NPC behavior, structures, inventory, combat, survival, and save data were not intentionally changed.
- Weather-driven wet/cold calculations were verified through playtest and left unchanged.
- Capture-only water fixture edits are isolated to `VisualCaptureRunner` and do not affect gameplay world generation.
