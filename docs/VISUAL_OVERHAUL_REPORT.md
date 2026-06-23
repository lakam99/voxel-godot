# Visual Overhaul Report

## Scope

This report closes Phase 11 of the visual overhaul. The final pass did not add a new visual feature category. It audited and tuned the existing overhaul for consistency, generated asset reuse, shadow policy, visibility ranges, test coverage, deterministic world output, and local capture performance.

Final Phase 11 code changes:

- `scripts/visual/VisualAssetRegistry.gd`: generated environment assets now receive a family-based render policy when instantiated.
- `scripts/visual/CharacterAssetRegistry.gd`: generated character parts now receive a shared render policy when instantiated.
- `scripts/PlaytestRunner.gd`: added `generated_visual_render_policy` coverage for trees, rocks, bushes, and NPC parts.

## Before/After Capture Index

Baseline captures are from Phase 1, before art-direction changes. Final captures are from the second Phase 11 capture run.

| Case | Phase 1 baseline | Final Phase 11 capture | Notes |
|---|---|---|---|
| `town_noon` | `artifacts/baselines/visual/phase1/town_noon.png` | `artifacts/visual/phase11-pass2/town_noon.png` | Cozy terrain, buildings, detail props, HUD hidden |
| `town_sunset` | `artifacts/baselines/visual/phase1/town_sunset.png` | `artifacts/visual/phase11-pass2/town_sunset.png` | Warm dusk lighting and fog retained |
| `forest_midnight` | `artifacts/baselines/visual/phase1/forest_midnight.png` | `artifacts/visual/phase11-pass2/forest_midnight.png` | Darker night, readable silhouettes, batched stars |
| `forest_rain` | `artifacts/baselines/visual/phase1/forest_rain.png` | `artifacts/visual/phase11-pass2/forest_rain.png` | Rain/cloud atmosphere, forest material palette |
| `mountain_day` | `artifacts/baselines/visual/phase1/mountain_day.png` | `artifacts/visual/phase11-pass2/mountain_day.png` | Terrain shading and distant visibility tuned |
| `water_overcast` | `artifacts/baselines/visual/phase1/water_overcast.png` | `artifacts/visual/phase11-pass2/water_overcast.png` | Water tint and overcast rain state |
| `hud_gameplay` | `artifacts/baselines/visual/phase1/hud_gameplay.png` | `artifacts/visual/phase11-pass2/hud_gameplay.png` | Immersive HUD style retained |
| `water_clear` | none in Phase 1 | `artifacts/visual/phase11-pass2/water_clear.png` | Added later water capture case |
| `water_sunset` | none in Phase 1 | `artifacts/visual/phase11-pass2/water_sunset.png` | Added later water capture case |

Phase 11 capture repeat results:

- Pass 1 output: `artifacts/visual/phase11-pass1`
- Pass 2 output: `artifacts/visual/phase11-pass2`
- Aggregate metadata hash matched: `0C6C25384147F5F6253DB8C99E90779CA7121415810310E8DBFB80A85D2BBD9B`
- PNG hashes matched for `5/9` captures.
- The four PNG differences were byte-size-level renderer drift in `hud_gameplay`, `town_sunset`, `water_overcast`, and `water_sunset`; metadata stayed identical.

## Architecture Summary

- `VisualStyle.gd` centralizes the cozy palette and reusable material construction.
- Generated environment assets are built by `tools/blender/generate_environment_assets.py` and described by `assets/visual/generated/visual-manifest.json`.
- Generated character assets are built by `tools/blender/generate_character_assets.py` and described by `assets/visual/generated/characters/character-manifest.json`.
- `VisualAssetRegistry.gd` and `CharacterAssetRegistry.gd` load generated GLBs, provide deterministic stable-key selection, and keep primitive fallbacks available.
- Phase 11 added explicit render policy at registry instantiation time:
  - bushes: no shadows, `120.0` visibility range
  - logs: shadows, `160.0` visibility range
  - rocks: shadows, `220.0` visibility range
  - trees: shadows, `260.0` visibility range
  - character parts: shadows, `140.0` visibility range
- This keeps tiny details cheaper while preserving shadows on important nearby trees, rocks, buildings, and characters.
- Visual capture and world-signature scenes remain separate from gameplay scenes so visual validation does not consume or alter gameplay RNG.

## Generated Asset Inventory

Environment assets: `26` checked, `0` validation errors.

| Family | Count |
|---|---:|
| `broadleaf_tree` | 6 |
| `conifer_tree` | 4 |
| `savanna_tree` | 3 |
| `rock` | 6 |
| `bush` | 4 |
| `stump_log` | 3 |

Character assets: `30` checked, `0` validation errors.

| Family | Count |
|---|---:|
| `hostile_core` | 2 |
| `hostile_eye` | 3 |
| `hostile_head` | 5 |
| `hostile_shard` | 3 |
| `hostile_torso` | 5 |
| `npc_arm` | 2 |
| `npc_head` | 3 |
| `npc_headwear` | 4 |
| `npc_torso` | 3 |

Generated asset records and validation output:

- `assets/visual/generated/visual-manifest.json`
- `assets/visual/generated/environment-validation.json`
- `assets/visual/generated/environment/contact-sheet.png`
- `assets/visual/generated/characters/character-manifest.json`
- `assets/visual/generated/characters/character-validation.json`
- `assets/visual/generated/characters/contact-sheet.png`

## Test Results

Commands run in Phase 11:

```powershell
& 'C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' --headless --path . --quit
.\tools\blender\build-environment-assets.ps1 -SkipGenerate
.\tools\blender\build-character-assets.ps1 -SkipGenerate
.\tools\run-playtest.ps1
.\tools\run-world-signature.ps1
.\tools\run-visual-captures.ps1 -OutputDir .\artifacts\visual\phase11-pass1
.\tools\run-playtest.ps1
.\tools\run-world-signature.ps1
.\tools\run-visual-captures.ps1 -OutputDir .\artifacts\visual\phase11-pass2
git diff --check
```

Results:

- Godot script/project load check: passed.
- Environment asset validator: `26` checked, `0` errors.
- Character asset validator: `30` checked, `0` errors.
- Full playtest pass 1: `155` passed, `0` failed.
- Full playtest pass 2: `155` passed, `0` failed.
- Latest playtest debug value: `performance_playtest_debug_hud` frame `6.39`, hostiles `0.93`, HUD refresh keys `8`.
- New render-policy test: `generated_visual_render_policy` passed for tree, rock, bush, and NPC part meshes.
- Visual captures pass 1: `9` captures produced.
- Visual captures pass 2: `9` captures produced.

## Deterministic Signature Result

`.\tools\run-world-signature.ps1` was run twice in Phase 11.

- Baseline: `artifacts/baselines/world-signature/atlas-1492.json`
- Latest: `artifacts/world-signature/latest/atlas-1492.json`
- SHA256: `5C3081C399FCD25D9216A18D845048E6BA1C16B50BDD001EC30B3AE8DB729661`
- Result: latest signature matches committed baseline exactly.

## Relative Performance Table

Values compare Phase 1 baseline capture draw estimates against final Phase 11 pass 2 at the same seed, resolution, chunk radius, and capture cases.

| Case | Phase 1 Draw | Final Draw | Delta | Delta % | Props | Physics Bodies |
|---|---:|---:|---:|---:|---:|---:|
| `town_noon` | 6504 | 5295 | -1209 | -18.6% | 897 | 2188 |
| `town_sunset` | 6504 | 5295 | -1209 | -18.6% | 897 | 2188 |
| `forest_midnight` | 6697 | 5314 | -1383 | -20.7% | 954 | 2242 |
| `forest_rain` | 6538 | 5314 | -1224 | -18.7% | 954 | 2242 |
| `mountain_day` | 7276 | 5912 | -1364 | -18.7% | 1006 | 2294 |
| `water_overcast` | 6738 | 5360 | -1378 | -20.5% | 943 | 2237 |
| `hud_gameplay` | 6504 | 5295 | -1209 | -18.6% | 897 | 2188 |

Phase 11 performance gate result: passed. There is no persistent frame-time or draw-estimate regression greater than 20%; shared capture draw estimates are lower than the Phase 1 baseline.

## Known Visual Limitations

- Phase 11 uses visibility fade ranges, not true multi-mesh LOD tiers. The current result is adequate for the capture and playtest budgets, but large biome vistas may eventually need explicit LOD assets.
- PNG captures can still show tiny renderer-level byte drift between runs even when metadata and composition are stable.
- The performance table uses the project debug draw estimate and playtest debug frame value, not GPU timer queries.
- Modular character visuals intentionally avoid skeletons and armatures. This keeps the current equipment and use-animation systems simple, but limits animation fidelity.
- `run-world-signature.ps1` may still print the existing ObjectDB shutdown warning while exiting successfully with a matching signature.

## Exact Asset Rebuild Commands

Full rebuild:

```powershell
.\tools\blender\build-environment-assets.ps1
.\tools\blender\build-character-assets.ps1
```

Validation only:

```powershell
.\tools\blender\build-environment-assets.ps1 -SkipGenerate
.\tools\blender\build-character-assets.ps1 -SkipGenerate
```

Functional and visual verification:

```powershell
.\tools\run-playtest.ps1
.\tools\run-world-signature.ps1
.\tools\run-visual-captures.ps1 -OutputDir .\artifacts\visual\phase11-pass1
.\tools\run-visual-captures.ps1 -OutputDir .\artifacts\visual\phase11-pass2
```
