# Visual Phase 10 Report

## Scope

Phase 10 replaces NPC and hostile primitive body shapes with generated modular low-poly parts while preserving existing gameplay systems.

Implemented:

- Added a Blender character asset generator and build wrapper:
  - `tools/blender/generate_character_assets.py`
  - `tools/blender/build-character-assets.ps1`
- Generated and validated 30 GLB character parts in `assets/visual/generated/characters`.
- Added `CharacterAssetRegistry` for loading generated parts, cloning scenes, and remapping material slots at runtime.
- Reworked NPC visuals to assemble torsos, heads, headwear, and arms from generated assets.
- Reworked hostile visuals to assemble torsos, heads, eyes, cores, and shards from generated assets.
- Preserved capsule collision, combat stats, AI behavior, equipment anchors, and use animations.
- Added primitive visual fallback paths when generated assets are missing or disabled.
- Changed NPC name labels so they only show when nearby, targeted, or in dialogue, and no longer draw through geometry.
- Routed tutorial NPCs through the same visual factory so they share the upgraded body style.

## Files Changed

- `assets/visual/generated/characters/*`
- `scripts/visual/CharacterAssetRegistry.gd`
- `scripts/NpcVisualFactory.gd`
- `scripts/HostileVisualFactory.gd`
- `scripts/NpcSystem.gd`
- `scripts/TutorialSceneBuilder.gd`
- `scripts/PlaytestRunner.gd`
- `tools/blender/generate_character_assets.py`
- `tools/blender/build-character-assets.ps1`

## Verification

Commands run:

```powershell
.\tools\blender\build-character-assets.ps1
.\tools\run-playtest.ps1
.\tools\run-world-signature.ps1
.\tools\run-visual-captures.ps1
git diff --check
```

Results:

- Character asset validation: 30 checked, 0 errors.
- Playtest: 154 passed, 0 failed.
- World signature: matches `artifacts\baselines\world-signature\atlas-1492.json`.
- Visual captures: generated successfully with Vulkan/Forward Plus.
- Diff whitespace check: passed.

## Key Automated Checks

- `character_asset_pack_ready`: registry ready, NPC and hostile asset families available, 30 assets loaded across 9 families.
- `modular_npc_visuals`: generated NPC parts present, expected meshes found, far labels hidden, nearby labels visible.
- `modular_hostile_visuals`: generated hostile parts present and capsule collision preserved.
- `character_visual_fallback`: primitive fallback path works when the registry is disabled.

## Capture Outputs Checked

- `artifacts\visual\latest\hud_gameplay.png`
- `artifacts\visual\latest\town_noon.png`
- `artifacts\visual\latest\town_sunset.png`
- `assets\visual\generated\characters\contact-sheet.png`

## Notes

- This pass intentionally avoids skeletons and armatures. Character parts stay modular so existing equipment anchors and lightweight use animations remain simple.
- The generated hostile silhouettes are still compatible with the current enemy variants; deeper boss or creature variety should happen in a later gameplay pass.
- `run-world-signature.ps1` still prints the existing ObjectDB leak warning at shutdown, but exits successfully with a matching signature.
