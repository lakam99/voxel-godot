# Visual Phase 5 Report

## Summary

Phase 5 adds an offline Blender asset factory without integrating the generated assets into gameplay visuals yet.

The pass creates deterministic low-poly environment assets, exports them as GLB files, writes a manifest with geometry and validation metadata, validates the generated files through Blender and Node.js, and imports the GLBs through Godot headlessly to verify scale, orientation, material slots, and pivots.

No world generation, `make_tree()`, `make_rock()`, prop spawning, gameplay collisions, drops, or falling-tree behavior were changed in this phase.

## Added Files

- `tools/blender/find-blender.ps1`
- `tools/blender/generate_environment_assets.py`
- `tools/blender/validate_generated_assets.py`
- `tools/blender/build-environment-assets.ps1`
- `tools/art/validate-visual-manifest.mjs`
- `scripts/visual/GeneratedAssetImportCheck.gd`
- `assets/visual/generated/visual-manifest.json`
- `assets/visual/generated/environment-validation.json`
- `assets/visual/generated/godot-import-check.json`
- `assets/visual/generated/environment/contact-sheet.png`
- `assets/visual/generated/environment/*.glb`

No `.blend` file is required or committed. The Python generator is the source of truth.

## Generated Pack

Deterministic generator:

- Version: `phase5-environment-v1`
- Seed: `1492`
- Triangle limit: `2200`
- Output directory: `assets/visual/generated/environment`

Generated assets:

| Family | Count | Triangle Range |
|---|---:|---:|
| `broadleaf_tree` | 6 | 180-268 |
| `conifer_tree` | 4 | 140-172 |
| `savanna_tree` | 3 | 204-292 |
| `rock` | 6 | 20-80 |
| `bush` | 4 | 80-164 |
| `stump_log` | 3 | 88-160 |

Material vocabulary:

- `trunk`
- `bark_dark`
- `cut_wood`
- `leaf_primary`
- `leaf_secondary`
- `leaf_warm`
- `needle_primary`
- `needle_secondary`
- `savanna_leaf`
- `rock_primary`
- `rock_accent`
- `moss`

Each manifest entry includes ID, path, family, biome tags, triangle count, bounding box, pivot/grounding checks, and material slots.

## Visual Gate

Contact sheet:

`assets/visual/generated/environment/contact-sheet.png`

Review notes:

- Broadleaf, conifer, and savanna silhouettes are distinguishable.
- Rocks are faceted and varied rather than egg-shaped.
- Bushes, stumps, and logs share the same low-poly material family.
- Contact sheet framing was widened so all variants can be reviewed in one artifact.
- Scale and pivots are backed by the Blender validator and Godot import check.

## Validation

Final asset commands run:

```text
.\tools\blender\build-environment-assets.ps1
```

```text
& "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe" --headless --path . --script res://scripts/visual/GeneratedAssetImportCheck.gd
```

Results:

- Blender detection: `C:\Program Files\Blender Foundation\Blender 5.1\blender.exe`
- Blender generator: generated 26 GLB assets.
- Blender import validator: `passed=true`, `checked=26`.
- Node manifest validator: valid manifest with 26 assets.
- Godot import validator: `passed=true`, `checked=26`.
- Idempotence: `idempotent=True files=30 changed=0`.

Known warning:

- Blender 5.1 reports a non-blocking deprecation warning for `Material.use_nodes`, which is expected to be removed in Blender 6.0.

## Regression Verification

Commands run:

```text
.\tools\run-playtest.ps1
.\tools\run-world-signature.ps1
.\tools\run-visual-captures.ps1
```

Results:

- Playtest: `143/143` assertions passed.
- World signature: matched `artifacts/baselines/world-signature/atlas-1492.json`.
- Visual captures: 9 capture cases generated in `artifacts/visual/latest`.

The world signature match is the key regression gate for this phase because the generated assets are not yet connected to world generation.

## Scope Notes

- This phase intentionally does not replace in-game tree or rock visuals.
- This phase intentionally does not edit `make_tree()` or `make_rock()`.
- This phase intentionally does not change terrain, chunk streaming, collision, NPCs, inventory, structures, combat, survival, weather, or save data.
- Phase 6 should integrate these assets through a registry/profile layer and preserve existing gameplay behavior.
