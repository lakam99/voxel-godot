# VOX-118 Canopy Baseline and Regression Firewall

Date: 2026-07-14  
Branch: `codex/vox-117-procedural-canopy`  
Fixed visual/signature seed: `atlas-1492`  
Fresh normal-runtime seed: `atlas-39704897`

This baseline follows `CODEX_VISUAL_UPGRADE_PLAN.md` by measuring the existing generated visual pipeline before replacing assets, and `CODEX_PERFORMANCE_PLAN.md` by separating existing runtime hitches from future canopy costs. It also preserves the tutorial-town publication and NPC boundaries in `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`: vegetation work cannot bypass town readiness, collision-backed routes, or ordinary production NPC behavior.

## Baseline result

Phase 2 may proceed. The protected NPC suite is green, fixed-seed generation is repeatable, and all five biome captures expose the intended problem: current tree assets are too short and narrow to form overhead cover. Two pre-existing failures are recorded rather than migrated or hidden:

- The tracked world-signature baseline contains an older 32-prop sample while two fresh `atlas-1492` runs each contain the same 4-prop sample. The two fresh files are byte-identical. This is a stale-baseline mismatch, not nondeterminism, and the tracked baseline was not updated.
- Normal sprint traversal recorded a 100.991 ms frame. The dominant section was the terrain meshing job queue at 96.310 ms. This is the existing terrain/chunk hitch investigated separately from canopy work.

## Existing tree and ground-detail authority

- Each chunk performs exactly 28 surface-prop attempts.
- Per attempt the deterministic RNG order is: X sample, Z sample, terrain/filter checks without RNG, then one prop roll. Additional random draws occur only inside the selected prop constructor. Later phases must not insert or reorder draws in this sequence.
- Tree roll widths are forest 0.58, taiga 0.48, plains 0.22, swamp 0.26, savanna 0.10, and default 0.02. Before placement filters and rock precedence, that is a theoretical homogeneous-chunk maximum of 16.24, 13.44, 6.16, 7.28, and 2.80 tree selections respectively.
- Runtime tree specifications are 3.0–5.2 m tall, with taiga/snow/tundra adding 1.6 m. Broadleaf procedural fallback crowns use five clumps; conifers use three.
- Imported generated trees are scaled to target height, clamped to 0.55–1.55, then multiplied by the biome visual-profile scale.
- Interactive tree trunks have collision radius 0.36 m and height equal to the runtime tree specification. Leaves are visual-only.
- Ground details use 53 attempts per chunk under the default density multiplier, then batch by detail family into `MultiMeshInstance3D` nodes. Detail shadows are disabled and visibility fading is self-relative.
- Forest/taiga detail distribution is leaf litter 0.34, grass to 0.78, then flowers. Swamp uses reeds 0.50 then grass. Savanna/desert uses scrub 0.44 then pebbles.
- Generated tree visibility is 260 m and trees cast shadows. The general visual-profile default is 180 m, matching the directional-shadow maximum. These ranges must be re-evaluated with the larger silhouettes rather than blindly retained.
- The pre-canopy fixture sway key was a no-op and was removed from every test in VOX-123. Production wind now uses the shared shader-global field and generated vertex masks described by VOX-121.

## Current generated tree metrics

| Family | Count | Height range | Crown width/depth range | Triangle range | Material roles |
|---|---:|---:|---:|---:|---|
| Broadleaf | 6 | 4.87–5.77 m | 2.17–2.85 / 2.12–2.43 m | 180–268 | trunk, bark dark, two leaf roles |
| Conifer | 4 | 5.07–6.04 m | 2.04–2.13 / 2.04–2.13 m | 140–172 | trunk, two needle roles |
| Savanna | 3 | 3.86–4.29 m | 2.72–2.93 / 1.56–1.70 m | 204–292 | trunk, bark dark, savanna leaf |

At these dimensions even the forest's theoretical density does not reliably create overhead cover. The fixed-seed signature observed only two trees across 37 loaded chunks, while the biome capture runner allowed 120 fixed frames for budgeted prop/detail publication. This timing gap is another reason to retain budget-aware visual acceptance rather than infer canopy quality from counts alone.

## Visual matrix

Command used the current Godot 4.6.1 console executable with `VOXEL_CANOPY_CAPTURE=1`. Evidence is under `artifacts/visual/vox118-canopy/`.

| Capture | Resolved cell | Finding |
|---|---:|---|
| Plains midday | (0, 7) | Open horizon; isolated, narrow vegetation; no overhead shade. |
| Forest midday | (0, 0) | Forest reads as sparse open ground, not a canopy. |
| Taiga midday | (-28, 217) | Small conifers do not form a roof or corridor. |
| Swamp rain | (14, -28) | Weather mood works, but the vertical foliage layer is absent. |
| Savanna midday | (-7, 14) | Sparse silhouette is biome-appropriate, but existing trees remain underscaled. |
| Forest storm | (0, 0) | Storm contrast works; no canopy movement or shadow pattern exists. |
| Forest night + torch | (0, 0) | Torch readability is preserved in the current open forest. |
| Forest traversal line | (0, 0) | The forward path has no enclosing crown layer. |
| Town edge midday | tutorial-town preset | Capture landed beside a building wall and is unsuitable as vegetation acceptance evidence. Replace the camera preset before VOX-123. |

## Determinism and gameplay firewall

World signature command was run twice for `atlas-1492`:

- `artifacts/world-signature/vox118/atlas-1492-run1.json`
- `artifacts/world-signature/vox118/atlas-1492-run2.json`
- SHA-256 for both: `F38645E945E10CC88DB6652A5F37B974F230F3893141B85FD3638BDA017FCACB`
- Both contain 37 loaded chunks, 4 props, 1,300 generated blocks, and 12 terrain samples.

The full registered NPC suite passed 17/17 with zero failures at `artifacts/npc/reports/all-npc-both.json`. The final-rescue runner is intentionally God mode because it is choreography acceptance; it proves the Mira briefing, staged Niko/Sera/hostile setup, live combat flow, return, and guard restoration, but it does not prove player survivability or damage balance. Dedicated evidence is `artifacts/npc/reports/vox116-final-rescue-godmode.json`.

## Runtime performance baseline

Command:

```powershell
.\tools\run-normal-runtime-performance-pass.ps1 -GodotExe 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' -Scenario NormalSprintTraversal -DurationSeconds 75 -WarmupFrames 120 -ReportPath artifacts\performance\vox118-normal-sprint.json -ScreenshotPath artifacts\performance\vox118-normal-sprint.png
```

Report: `artifacts/performance/vox118-normal-sprint.json`

- 433 measured samples; 691.58 m automated sprint travel; 140 chunks created.
- Frame p50 10.062 ms, p95 15.716 ms, p99 18.167 ms, maximum 100.991 ms.
- Worst reason: `chunk` 97.173 ms, dominated by `terrain_meshing_job_queue` 96.310 ms.
- Maximum prop-spawn section: 13.002 ms.
- Maximum NPC section: 1.076 ms.
- Failure: maximum frame time exceeded the 33 ms threshold.

VOX-120–122 must not increase tree-selection RNG calls, per-frame node iteration, or synchronous spawn work. VOX-123 will repeat this traversal and compare both percentiles and the tree/prop sections, while keeping the known terrain-meshing spike separately attributed.
