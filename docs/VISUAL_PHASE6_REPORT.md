# Visual Phase 6 Report

## Summary

Phase 6 replaces the visible tree and rock primitives with the deterministic GLB assets generated in Phase 5.

The gameplay roots remain the same: trees and rocks still use the existing `StaticBody3D` roots, metadata, drops, targeting behavior, primitive collision shapes, and falling-tree flow. The generated asset is now a visual child beneath that gameplay body. If an asset is unavailable, the old primitive construction path is still used as a fallback.

## Added Files

- `scripts/visual/VisualAssetRegistry.gd`
- `scripts/visual/BiomeVisualProfile.gd`
- `resources/visual/biomes/alpine.tres`
- `resources/visual/biomes/beach.tres`
- `resources/visual/biomes/default.tres`
- `resources/visual/biomes/desert.tres`
- `resources/visual/biomes/forest.tres`
- `resources/visual/biomes/plains.tres`
- `resources/visual/biomes/savanna.tres`
- `resources/visual/biomes/snow.tres`
- `resources/visual/biomes/swamp.tres`
- `resources/visual/biomes/taiga.tres`
- `resources/visual/biomes/tundra.tres`

## Changed Files

- `scripts/MainInterface.gd`
- `scripts/MainCore.gd`
- `scripts/MainPlaytestTools.gd`
- `scripts/PlaytestRunner.gd`
- `scripts/visual/VisualCaptureRunner.gd`
- `scripts/visual/WorldSignatureRunner.gd`
- `artifacts/baselines/world-signature/atlas-1492.json`

## Integration Details

`VisualAssetRegistry` reads `assets/visual/generated/visual-manifest.json`, loads the biome visual profile resources once, imports each GLB through `GLTFDocument`, and caches the result as a `PackedScene`. Tree and rock creation paths instantiate cached scenes only; there are no per-prop `load()` calls and no per-prop material creation.

Biome profiles choose asset families and scale modifiers by biome. Variant selection is deterministic by biome plus stable `prop_id`, so visual choices do not consume the chunk-generation RNG.

`make_tree()` and `make_rock()` now extract the old visual random draws into spec helpers before attaching either generated visuals or primitive fallbacks. The draw order was preserved so later prop generation is not shifted.

Generated visuals are added as child nodes named `GeneratedTreeVisual` or `GeneratedRockVisual` and marked with `visual_source = "generated_asset"`. Fallback visuals keep `visual_source = "primitive_fallback"`.

## Signature Note

`WorldSignatureRunner` no longer records prop node `name`.

That field was a volatile Godot auto-name and changed when generated visual children were introduced, even though gameplay identity and placement did not change. The baseline was regenerated after removing that field. Stable signature fields still cover prop id, kind, material, drop metadata, positions, terrain, blocks, structures, and town records.

Final signature result:

```text
World signature matches baseline: artifacts/baselines/world-signature/atlas-1492.json
```

## Visual Gate

Capture run:

```text
.\tools\run-visual-captures.ps1
```

Results:

- 9 capture cases generated in `artifacts/visual/latest`.
- Forest rain and forest midnight show the new branchy tree silhouettes and faceted stones.
- Mountain day now uses a higher capture vantage and shows generated trees and rocks on the mountain surface.
- Capture metadata remained stable at 49 chunks per case.

## Regression Verification

Commands run:

```text
.\tools\run-playtest.ps1
.\tools\run-world-signature.ps1
.\tools\run-visual-captures.ps1
& "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe" --headless --path . --script res://scripts/visual/GeneratedAssetImportCheck.gd
git diff --check
```

Results:

- Playtest: `145/145` assertions passed.
- Generated prop test: registry ready, 26 assets, 11 biome profiles, cached scene count `26->26`.
- Fallback prop test: deliberately disabled tree and rock assets produced primitive fallbacks with collisions intact.
- Falling tree test: `tree_fall_visual_and_logs` passed, logs `34->37`.
- Performance HUD test: passed with frame time `3.88` and hostiles `0.48`.
- Godot asset import check: imported 26 generated assets.
- World signature: matched the committed baseline.
- `git diff --check`: no whitespace errors.

Known warning:

- `run-world-signature.ps1` exits successfully but prints Godot's `ObjectDB instances leaked at exit` warning. This appears to be shutdown cleanup from cached GLTF/PackedScene resources and did not fail the regression gate.

## Scope Notes

- This phase replaces only tree and rock visual children.
- This phase does not replace forage, wildlife, ore, small detail batches, buildings, characters, blocks, HUD, combat, NPC logic, inventory, or terrain generation.
- Primitive tree and rock visuals remain available as deterministic fallbacks.
