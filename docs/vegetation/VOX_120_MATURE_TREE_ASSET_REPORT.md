# VOX-120 Mature Tree Asset Report

Date: 2026-07-14
Branch: `codex/vox-117-procedural-canopy`

## Outcome

The deterministic Blender environment pipeline now produces 13 finite, low-poly canopy trees in four generated families. After direct visual review rejected the first crown treatment, the assets were rebuilt around hundreds of individually readable, branch-attached folded leaf solids instead of a few large foliage blobs. Broadleaf and savanna crowns were also widened so their silhouettes read as walk-under shade canopies at whole-tree scale.

The assets remain build-time-only with `runtimeEnabled: false`. VOX-120 does not change biome selection, generated worlds, saves, collision, drops, terrain, navigation, town publication, or NPC behavior. This preserves the boundary in `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`: tutorial-town readiness still completes before gameplay, and neither asset generation nor `VisualAssetRegistry` can become a late town/NPC repair path. The existing 26 runtime environment assets remain the complete live registry until VOX-122.

## Generated families

| Family | Count | Height | Canopy width | Folded leaves / needles | Triangles |
| --- | ---: | ---: | ---: | ---: | ---: |
| `mature_broadleaf_tree` | 4 | 10.39-15.55 m | 9.23-13.93 m | 252-402 | 1,316-2,000 |
| `old_growth_broadleaf_tree` | 2 | 19.40-21.63 m | 16.05-16.52 m | 339-399 | 1,808-2,104 |
| `mature_conifer_tree` | 4 | 11.74-17.40 m | 6.30-8.15 m | 242-333 | 1,516-2,088 |
| `mature_savanna_tree` | 3 | 8.79-12.36 m | 11.59-13.86 m | 191-293 | 1,052-1,572 |

Every variant remains below the 2,200-triangle environment limit. Old-growth broadleaf width has an explicit 18 m validation ceiling; all other mature canopy families retain the 16 m ceiling. This is a family-specific asset contract, not an unbounded validator relaxation.

Each foliage primitive is a shallow folded diamond containing four triangles. Hundreds of those leaves are aggregated into one foliage object and ultimately one exported mesh with shared material surfaces. This keeps the crown visually granular without creating hundreds of runtime nodes or per-leaf draw calls.

## Review evidence

The deterministic whole-tree sheet is:

`assets/visual/generated/environment/canopy-contact-sheet-v3.png`

It presents all 13 variants at one orthographic scale and is the silhouette gate for tree height, trunk-to-crown proportion, crown width, and family identity.

The deterministic foliage-only sheet is:

`assets/visual/generated/environment/canopy-leaf-detail-sheet-v3.png`

It strips trunk and branch faces from representative review copies and proves that broadleaf, old-growth, conifer, and savanna foliage is composed of many distinct folded leaves or needle sprays. The exported GLBs remain unchanged one-mesh assets.

## Wind-ready static asset contract

Every generated tree, including compatibility trees, exports one `COLOR_0` vertex channel sourced from Blender's `wind` color attribute:

- R: main bend weight; root vertices are immobile and crown weights rise toward one.
- G: deterministic per-vertex phase variation.
- B: foliage/detail flutter weight.
- A: reserved/AO channel, currently one.

The manifest records material roles, dimensions, crown/trunk metrics, foliage primitive counts and structure, channel ranges, root/crown proof, and static-animation counts. GLB export explicitly disables animation, morph targets, and skins. No skeleton, shape key, baked clip, physics rig, or per-world unique model is introduced.

VOX-121 consumes these channels through shared shader/system contracts. VOX-120 does not install a wind shader or move trees at runtime.

## Pipeline and validators

The single build entry point is:

```powershell
.\tools\blender\build-environment-assets.ps1 -BlenderPath 'C:\Program Files\Blender Foundation\Blender 5.1\blender.exe'
```

It runs four gates:

1. deterministic Blender generation;
2. Blender re-import validation for bounds, material roles, wind colors, foliage structure, and static-only assets;
3. Node manifest/schema validation for 39 total assets and exact family requirements;
4. Godot 4.6.1 GLTF import contract validation.

Result: 6/6 Godot import checks passed, all 13 canopy GLBs imported, and the runtime registry remained 26/26 with none of the dormant IDs exposed. Report: `artifacts/vegetation/canopy-asset-import-contract.json`.

The prior biome-catalog contract also passed 12/12 after the registry firewall change. Report: `artifacts/vegetation/vox120-biome-catalog-regression.json`.

## Deterministic rebuild proof

The full Blender -> Blender validation -> Node validation -> Godot import pipeline was run twice without intervening source changes. SHA-256 comparison covered all 39 GLBs, the manifest, the Blender validation report, the whole-tree sheet, and the foliage-detail sheet: 43/43 files matched byte-for-byte with zero mismatches.

- manifest SHA-256: `B93F2E7319F5D8467B511D0829D90E69FEB37A7CF8AFD47FBF1735BA725B3ADC`
- whole-tree sheet SHA-256: `5D83CF40421B412603A3C338F3DFBCA68AA58724C1370EBD386BD45000CCE272`
- foliage-detail sheet SHA-256: `3D946ED9CAAF0D79B1969F1CBD63A1873EC54FA1B05632871972666EFC4890A6`

Blender 5.1 emitted only its forward-looking `Material.use_nodes` deprecation warning for Blender 6.0; generation and every validator exited successfully.

## Evidence boundary

This phase proves deterministic asset generation, visible leaf construction, crown silhouette, and Blender/Godot import integrity. It does not claim live biome density, runtime sway, moving shadows, collision, chopping, save persistence, NPC navigation, or performance acceptance; those remain VOX-121 through VOX-123 work.
