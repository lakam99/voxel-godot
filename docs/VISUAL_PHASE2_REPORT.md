# Visual Phase 2 Report

Phase 2 introduces a data-driven visual style and repairs the environment lighting. It does not intentionally change terrain geometry, terrain materials, props, structures, water behavior, UI, input, collision, saves, or procedural generation.

## Added

- `scripts/visual/VisualStyle.gd`
- `resources/visual/gamecube_style.tres`
- `artifacts/baselines/visual/phase2/`

The Phase 2 capture set and contact sheet are committed under:

- `artifacts/baselines/visual/phase2/*.png`
- `artifacts/baselines/visual/phase2/*.json`
- `artifacts/baselines/visual/phase2/phase2-contact-sheet.png`

Before captures remain in:

- `artifacts/baselines/visual/phase1/`

## Lighting Changes

- Replaced `Environment.BG_COLOR` with `Environment.BG_SKY` using a `ProceduralSkyMaterial`.
- Added explicit filmic tonemapping with calibrated exposure and white point from `gamecube_style.tres`.
- Moved sky, ambient, fog, sunlight, moonlight, weather tint, shadow, and SSAO values into `gamecube_style.tres`.
- Switched ambient lighting to sky-sourced lighting with coordinated ambient color and energy.
- Reduced the noon sun from the previous high clipping range to a lower controlled range.
- Raised night ambient and moonlight so terrain, trees, rocks, and props remain readable.
- Added restrained fog that follows sky/time/weather color.
- Configured directional shadow distance, fade, blur, and angular distance.
- Preserved existing sun and moon disc nodes.

## Visual Review

Contact sheet:

```text
artifacts/baselines/visual/phase2/phase2-contact-sheet.png
```

Observed changes:

- `town_noon`: sand and pale paths no longer blow out to flat white/yellow.
- `town_sunset`: stronger warm sky response and less clipped direct light.
- `forest_midnight`: trunks, terrain, rocks, and nearby props remain visible instead of falling into near-black.
- `forest_rain` and `water_overcast`: rain cools and darkens the scene while preserving silhouettes.
- `hud_gameplay`: UI remains readable over the revised lighting.
- `mountain_day`: fixed capture framing remains very close to terrain in both phases; no camera or terrain changes were made in this phase.

## Verification

Pre-edit playtest command:

```powershell
.\tools\run-playtest.ps1
```

Pre-edit result:

- Passed: `true`
- Result count: `137`
- Shell wall time: approximately `112.2` seconds
- `performance_playtest_debug_hud`: frame `4.47`, hostiles `0.62`, HUD refresh keys `8`

Post-edit playtest command:

```powershell
.\tools\run-playtest.ps1
```

Post-edit result:

- Passed: `true`
- Result count: `138`
- Shell wall time: approximately `112.8` seconds
- `performance_playtest_debug_hud`: frame `4.22`, hostiles `0.49`, HUD refresh keys `8`
- New assertion `environment_visual_style` passed:
  - sky `true`
  - filmic `true`
  - sky ambient `true`
  - fog `true`
  - SSAO `true`
  - noon sun `1.21`
  - noon ambient `0.51`
  - noon fog `0.0079`
  - night sun `0.03`
  - night moon `0.20`
  - night ambient `0.18`
  - night fog `0.0112`

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

Phase 1 and Phase 2 capture metadata kept the same gameplay-relevant counts:

| Case | Draw Estimate | Physics Bodies | Props | Blocks |
|---|---:|---:|---:|---:|
| `town_noon` | `6504 -> 6504` | `2188 -> 2188` | `897 -> 897` | `1219 -> 1219` |
| `town_sunset` | `6504 -> 6504` | `2188 -> 2188` | `897 -> 897` | `1219 -> 1219` |
| `forest_midnight` | `6697 -> 6697` | `2242 -> 2242` | `954 -> 954` | `1216 -> 1216` |
| `forest_rain` | `6538 -> 6538` | `2242 -> 2242` | `954 -> 954` | `1216 -> 1216` |
| `mountain_day` | `7276 -> 7276` | `2294 -> 2294` | `1006 -> 1006` | `1216 -> 1216` |
| `water_overcast` | `6738 -> 6738` | `2250 -> 2250` | `956 -> 956` | `1222 -> 1222` |
| `hud_gameplay` | `6504 -> 6504` | `2188 -> 2188` | `897 -> 897` | `1219 -> 1219` |

## Performance Notes

The playtest frame debug value improved from the same-session pre-edit run (`4.47`) to the post-edit run (`4.22`). Compared to the Phase 1 report value (`3.83`), the result is within normal run-to-run variance for this test harness. Capture metadata shows no increase in draw estimate, prop count, block count, or physics body count.

No new meshes, terrain cells, collision bodies, weather meshes, structures, or UI controls were added by this phase.

## Scope Notes

- No custom sky shader was added. `ProceduralSkyMaterial` was sufficient for this pass.
- Existing water material behavior in weather lighting was preserved.
- The style resource is stored as a generic `Resource` in the main chain to avoid relying on global script-class registration during headless checks.
