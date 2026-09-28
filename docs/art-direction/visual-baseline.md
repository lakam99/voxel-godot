# Visual Baseline

Phase 0 checkpoint for the visual overhaul plan.

## Branch

- Branch: `visual-overhaul`
- Purpose: checkpoint all current game work before starting visual changes.

## Engine And Renderer

- Godot version: `4.6.1.stable.official.14d19694e`
- Project feature set: `4.6`, `Forward Plus`
- Main scene: `res://scenes/Main.tscn`
- Viewport: `1280x720`
- Current project clear color: `Color(0.66, 0.84, 0.87, 1)`

## Baseline Test Result

- Command: `.\tools\run-playtest.ps1`
- Timed wrapper: `$elapsed = Measure-Command { .\tools\run-playtest.ps1 }; 'ELAPSED_SECONDS={0:N2}' -f $elapsed.TotalSeconds`
- Elapsed time: `115.93` seconds
- Report file: `playtest-report.json` local generated output, ignored by Git
- Result count: `137`
- Passed: `137`
- Failed: `0`

## Key Performance And Debug Values

From the baseline playtest report:

- `performance_playtest_debug_hud`: blocks mouse true/true, playtest buttons true, route true, perf true, targets true/true, frame `6.50`, hostiles `0.87`, hud refresh keys `8`
- `hud_refresh_throttling`: skipped `3`, throttled before interval `0`, messages `1`, visible true, zero interval refreshes `1`
- `terrain_generation_profile`: normal `3374`, avg variation `0.73`, smooth `87%`, mountain samples `2`, max `68.96`, target `(133, 70)` height `68.66`
- `chunk_asset_cache_reuse_invalidation`: hits `160->160->203`, misses `734->777`, entries `96`, invalidations `85->94`
- `chunk_detail_batches`: chunks `49/49`, batches `225`, instances `2873`, colliders `0`, detail types `grass`, `pebble`, `scrub`, `flowerStem`, `flowerBloom`, `leafLitter`, `reed`, `snowClump`
- `town_generation_counts`: towns `3`, buildings `12`, paths `284`, doors `40`, utilities `42`
- `manual_playtest_cases`: all fixed cases present; cleanup true

## Current Visual Implementation Summary

- The project is still code-generated at runtime, with a code-only `Main.tscn`.
- There are `58` GDScript files and `21148` total GDScript lines.
- The current visual world is built mostly from procedural Godot primitives and runtime materials.
- `MainSetupScene.gd` owns material setup and the environment.
- `MainGameLoop.gd` owns sky, sun/moon, weather lighting, and music state updates.
- `MainPlaytestTools.gd` owns terrain mesh generation, chunk detail batches, trees, rocks, ore, forage, and wildlife visuals.
- `MainChunkTerrain.gd` owns block and placed-utility visuals, currently using primitive mesh pieces.
- `WeatherSystem.gd` owns cloud, star, rain, and snow visuals.
- `assets/` currently contains audio assets; no generated visual art asset pack has been introduced.
- The current debug/performance instrumentation is available through `debug_performance_state()` and the playtest/debug HUD.

## Exact Commands Used

```powershell
git branch --show-current
git branch --list visual-overhaul
git status --short --branch
git switch -c visual-overhaul
$elapsed = Measure-Command { .\tools\run-playtest.ps1 }
'ELAPSED_SECONDS={0:N2}' -f $elapsed.TotalSeconds
$report = Get-Content -LiteralPath playtest-report.json -Raw | ConvertFrom-Json
$report.results.Count
& 'C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' --version
rg -n "renderer|rendering_method|rendering" project.godot scripts\MainSetupScene.gd scripts\MainGameLoop.gd
```

## Phase 0 Notes

- No gameplay or visual implementation values were intentionally changed in this phase.
- `.godot/`, `playtest-report.json`, and `playtest-progress.txt` are ignored local/generated outputs.
- The deterministic visual capture and world-signature harnesses are intentionally not present yet; they are Phase 1 work.
