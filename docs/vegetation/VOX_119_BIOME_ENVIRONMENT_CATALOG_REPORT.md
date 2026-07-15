# VOX-119 Biome Environment Catalog Report

Date: 2026-07-14  
Branch: `codex/vox-117-procedural-canopy`

## Outcome

The former visual-only biome profiles are now `BiomeEnvironmentProfile` resources behind one cached `BiomeEnvironmentCatalog`. `WorldGenerationSystem` remains the classifier. The catalog is read-only presentation/environment data and has no terrain, structure, town, story, navigation, or NPC authority.

Main placement code, `VisualAssetRegistry`, and `WeatherSystem` receive the same catalog instance during startup. This follows the composition boundary in `AGENTS.md`, introduces no new `Main*.gd` inheritance layer, and keeps the tutorial-town readiness and NPC command ownership described by `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md` unchanged.

## Parity and deterministic generation

Profiles mirror the previous values for:

- tree, rock, forage, and wildlife chances;
- forage material/drop/range;
- tree and rock asset families/scales;
- precipitation and cloud response;
- cold-weather classification;
- ground-detail thresholds, offsets, and scale ranges.

The shared surface-prop RNG sequence remains X, Z, non-random filtering, and one prop roll, followed only by the selected constructor's existing draws. Catalog/profile/detail selection consumes no RNG. Ground detail still consumes exactly one selection roll and the same transform draws for the selected detail type.

Two post-catalog world signatures for `atlas-1492` are byte-identical to each other and to the fresh VOX-118 pre-catalog signature:

- `artifacts/world-signature/vox119/atlas-1492-run1.json`
- `artifacts/world-signature/vox119/atlas-1492-run2.json`
- SHA-256: `F38645E945E10CC88DB6652A5F37B974F230F3893141B85FD3638BDA017FCACB`

Both commands retain the expected exit 1 against the separately documented stale tracked baseline. No baseline or save migration was performed.

## Validation and fallback

The catalog loads 13 explicit profiles: default, ocean, beach, plains, forest, taiga, snow, tundra, alpine, savanna, desert, swamp, and town. Schema validation rejects empty IDs/families, mismatched detail arrays, invalid thresholds/scales, and invalid forage ranges. Duplicate IDs and missing resources produce bounded structured errors. Unknown biome IDs return the immutable default resource.

The profile includes neutral extension fields for VOX-120–122 tree dimensions, crown/trunk metrics, old-growth selection, wind response, canopy density, exclusions, and render range. This is only a data seam in VOX-119; no values are tuned and no visible behavior changes.

## Evidence

Focused command:

```powershell
.\tools\run-biome-environment-catalog-contract-tests.ps1 -GodotExe 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' -ReportPath artifacts\vegetation\vox119-biome-environment-contract.json
```

Result: 12/12 contract checks passed with zero failures. The runner is registered in `tools/test-runner-registry.json` and explicitly claims contract evidence only, not live visual acceptance.

The current main-menu -> New Game startup smoke passed with all 19 readiness domains, six registered production NPCs, and zero failures at `artifacts/vegetation/vox119-main-menu-startup-smoke.json`.

The broad legacy `PlaytestRunner` completed 184 checks with 13 failures at `artifacts/vegetation/vox119-playtest.json`. Those failures are recorded, not cited as catalog regressions: the runner queried zero legacy chunk-root bodies after the VoxelTerrain migration, expected direct helper-created drops to enter inventory, and retained legacy movement/steep-ascent assertions. The byte-identical signatures and green current startup smoke isolate this from VOX-119. These cases require a separate test-validity audit against the dedicated VoxelTerrain, underground, digging, and movement runners; gameplay was not modified to satisfy them and no assertion was weakened here.
