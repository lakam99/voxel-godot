# VOX-120 Mature Tree Asset Report

Date: 2026-07-14
Branch: `codex/vox-117-procedural-canopy`

## Outcome

The existing deterministic Blender environment generator now produces 13 finite, low-poly canopy trees in four generated families. They remain build-time assets with `runtimeEnabled: false`; no biome selects them and no generated world, save, collider, drop, terrain, navigation, town, or NPC behavior changes in VOX-120.

This preserves the composition and readiness boundaries in `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`: tutorial-town publication still completes before gameplay, and neither visual generation nor `VisualAssetRegistry` can become a late town/NPC repair path. The existing 26 runtime environment assets remain the complete live registry until VOX-122.

## Generated families

| Family | Count | Generated height range | Triangle range | Intended role |
| --- | ---: | ---: | ---: | --- |
| `mature_broadleaf_tree` | 4 | 10.48–13.39 m | 480–624 | Walk-under forest/plains/swamp canopy |
| `old_growth_broadleaf_tree` | 2 | 18.00–18.00 m | 744–840 | Rare forest canopy landmark |
| `mature_conifer_tree` | 4 | 11.55–17.19 m | 336–456 | Tall taiga/snow silhouette |
| `mature_savanna_tree` | 3 | 8.25–10.62 m | 468–660 | Broad, high acacia-like shade canopy |

Trunk radii range from 0.375 m to 0.790 m. Broadleaf canopy bases range from 5.77 m to 10.92 m; savanna bases range from 6.44 m to 8.41 m. Conifers retain naturally lower boughs while their trunks and crowns meet the requested mature height bands. All variants remain far below the 2,200-triangle environment limit.

The reviewed deterministic contact sheet is `assets/visual/generated/environment/contact-sheet.png`. It shows all 13 assets at one orthographic scale, ordered broadleaf → old growth/conifer → conifer/savanna, with the incomplete final row centered.

## Wind-ready static asset contract

Every generated tree, including compatibility trees, exports one `COLOR_0` vertex channel sourced from Blender's `wind` color attribute:

- R: main bend weight; root vertices are immobile and crown weights rise toward one;
- G: deterministic per-vertex phase variation;
- B: foliage/detail flutter weight;
- A: reserved/AO channel, currently one.

The manifest records per-tree material roles, dimensions, crown/trunk metrics, channel ranges, root/crown proof, and static-animation counts. GLB export explicitly disables animation, morph targets, and skins. No skeleton, shape key, baked clip, physics rig, or per-world unique model is introduced.

VOX-121 will consume these channels through shared shader/system contracts. VOX-120 does not install a wind shader or move a tree at runtime.

## Pipeline and validators

The existing wrapper remains the single build entry point:

```powershell
.\tools\blender\build-environment-assets.ps1 -BlenderPath 'C:\Program Files\Blender Foundation\Blender 5.1\blender.exe'
```

It now runs four gates in sequence:

1. deterministic Blender generation;
2. Blender re-import validation for bounds, material roles, wind colors, and static-only assets;
3. Node manifest/schema validation for 39 total assets and exact family requirements;
4. Godot 4.6.1 GLTF import contract validation.

The Godot runner is separately available as:

```powershell
.\tools\run-canopy-asset-import-contract-tests.ps1 -ReportPath artifacts\vegetation\vox120-canopy-import.json
```

Result: 6/6 contract checks passed, 13/13 canopy GLBs imported, and the runtime registry remained 26/26 with none of the dormant IDs exposed. Report: `artifacts/vegetation/vox120-canopy-import.json`.

The prior biome-catalog contract also passed 12/12 after the registry firewall change. Report: `artifacts/vegetation/vox120-biome-catalog-regression.json`.

## Deterministic rebuild proof

The full Blender → Blender validation → Node validation → Godot import pipeline was run twice without intervening source changes. SHA-256 comparison covered all 39 GLBs, the manifest, the Blender validation report, and the contact sheet: 42/42 files matched byte-for-byte with zero mismatches.

- manifest SHA-256: `37441DB12D2474493738DB0C9CC62AA05034D4CECBC5B8CBB73D05649AF22FD5`
- contact-sheet SHA-256: `B50C2C9468926852F110C34EF086E72FA500B0A5B03A6046CEB5603FEF610811`

Blender 5.1 emitted only its forward-looking `Material.use_nodes` deprecation warning for Blender 6.0; generation and every validator exited successfully.

## Evidence boundary

This phase proves deterministic asset generation and Blender/Godot import integrity. The contact sheet is asset-review evidence. It does not claim live biome density, runtime sway, shadow motion, collision, chopping, save persistence, NPC navigation, or performance acceptance; those remain VOX-121–123 work.
