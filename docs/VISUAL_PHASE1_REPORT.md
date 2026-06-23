# Visual Phase 1 Report

Phase 1 adds deterministic visual capture and world-signature protection. It does not intentionally change game visuals, gameplay, save data, collision, generation rules, or input behavior.

## Added

- `scenes/VisualCapture.tscn`
- `scenes/WorldSignature.tscn`
- `scripts/visual/VisualCaptureRunner.gd`
- `scripts/visual/WorldSignatureRunner.gd`
- `tools/run-visual-captures.ps1`
- `tools/run-world-signature.ps1`
- `artifacts/baselines/visual/phase1/`
- `artifacts/baselines/world-signature/atlas-1492.json`

Local generated output folders are ignored:

- `artifacts/visual/`
- `artifacts/world-signature/`

## Capture Baseline

Command:

```powershell
.\tools\run-visual-captures.ps1 -UpdateBaseline
```

Generated selected baseline files:

- `7` PNG captures
- `7` per-case JSON metadata files
- `1` aggregate `visual-captures.json`

Capture cases:

| Case | Clock | Weather | HUD | Chunks | Props | Blocks | Physics Bodies | Draw Estimate |
|---|---:|---|---|---:|---:|---:|---:|---:|
| `town_noon` | `12:00` | clear `0.00`, clouds `0.22` | hidden | 49 | 897 | 1219 | 2188 | 6504 |
| `town_sunset` | `18:42` | clear `0.00`, clouds `0.26` | hidden | 49 | 897 | 1219 | 2188 | 6504 |
| `forest_midnight` | `00:00` | clear `0.00`, clouds `0.18` | hidden | 49 | 954 | 1216 | 2242 | 6697 |
| `forest_rain` | `16:30` | rain `0.68`, clouds `0.88` | hidden | 49 | 954 | 1216 | 2242 | 6538 |
| `mountain_day` | `09:00` | clear `0.00`, clouds `0.30` | hidden | 49 | 1006 | 1216 | 2294 | 7276 |
| `water_overcast` | `14:30` | rain `0.18`, clouds `0.72` | hidden | 49 | 956 | 1222 | 2250 | 6738 |
| `hud_gameplay` | `12:00` | clear `0.00`, clouds `0.22` | visible | 49 | 897 | 1219 | 2188 | 6504 |

Repeat command:

```powershell
.\tools\run-visual-captures.ps1 -OutputDir .\artifacts\visual\repeat
```

Repeat validation:

- Metadata hashes matched for all `8` JSON files.
- PNG hashes matched for `5/7` captures.
- The two non-identical PNGs, `town_sunset.png` and `hud_gameplay.png`, had tiny sampled renderer-level pixel drift rather than composition changes:
  - `town_sunset.png`: sampled average channel-sum difference `0.0529`
  - `hud_gameplay.png`: sampled average channel-sum difference `0.1154`
- All captures used fixed seed `atlas-1492`, fixed camera transforms, fixed resolution `1280x720`, frozen player motion, frozen head bob, frozen hand sway, and forced time/weather.

## World Signature

Baseline command:

```powershell
.\tools\run-world-signature.ps1 -UpdateBaseline
```

Comparison command:

```powershell
.\tools\run-world-signature.ps1
```

Result:

- World signature matched committed baseline.
- Baseline SHA256: `F860C61DA745BEC87EF8651C4F5086028F20DCC5F00B6489400252AC04B654BB`

The signature records fixed terrain samples, loaded chunk keys, prop IDs/kinds/materials/drop/positions, generated structure counts, generated tier counts, generated town block records, and town home records.

## Playtest

Command:

```powershell
.\tools\run-playtest.ps1
```

Result:

- Passed: `true`
- Result count: `137`
- Shell wall time: approximately `109.9` seconds

Selected debug values from the final report:

- `performance_playtest_debug_hud`: frame `3.83`, hostiles `0.48`, HUD refresh keys `8`
- `terrain_generation_profile`: normal `3374`, avg variation `0.73`, smooth `87%`, mountain samples `2`, max `68.96`
- `chunk_detail_batches`: chunks `49/49`, batches `225`, instances `2873`, colliders `0`

Relative to Phase 0, no performance regression is expected from runtime gameplay because this phase only adds external capture/signature scenes and tools. The playtest debug frame value changed from `6.50` in Phase 0 to `3.83` in this run, which is normal run-to-run measurement variance and not from a gameplay code path change.

## Notes

- Visual captures intentionally run with a real Vulkan Forward+ viewport, not Godot `--headless`, because this Windows Godot build uses the dummy renderer in headless mode and cannot read a viewport image.
- The capture runner disables tutorial storm overrides only in the isolated capture scene so required clear/rain/overcast cases are truthful.
- Wildlife runtime drift is normalized to stable `wildlife_home` positions in the world signature so animated props do not cause false generation mismatches.
