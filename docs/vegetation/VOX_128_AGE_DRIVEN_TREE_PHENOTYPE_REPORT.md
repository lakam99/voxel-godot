# VOX-128 Age-Driven Tree Phenotype Report

## Outcome

The existing Blender environment pipeline now produces a finite ecological library of 30 reusable trees: three architectures, five age bands, and two deterministic variants per band. The full environment manifest contains 69 assets. No runtime procedural mesh generation or second asset pipeline was introduced.

## Generated architecture

- Broadleaf trees use tapered radial tiers, asymmetric forks, secondary/tertiary structure, terminal sprays, and rounded crowns.
- Conifers use age-scaled trunks, whorled boughs, taper, and a vertical needle crown.
- Savanna trees use upward leaders and broad, flatter secondary crowns.

Age independently increases height, trunk radius/taper, crown extent, primary branches, branch generations, terminal tips, and attached leaves. Approximate generated height envelopes are:

| Architecture | Young | Established | Mature | Old | Ancient |
| --- | ---: | ---: | ---: | ---: | ---: |
| Broadleaf | 10 m | 16 m | 25 m | 32 m | 39 m |
| Conifer | 11 m | 17 m | 25 m | 34 m | 43 m |
| Savanna | 9 m | 14 m | 20 m | 26 m | 32 m |

Leaf-card budgets rise from roughly 320 on young variants to 3,020-3,240 on ancient variants. The largest ecological asset is 4,672 triangles, below its 6,200-triangle cap. Foliage is generated from eligible branch terminals and exported as part of one static mesh, not as runtime leaf nodes.

## Validation and review

Review sheets:

- `assets/visual/generated/environment/tree-ecology-contact-sheet-v1.png`
- `assets/visual/generated/environment/tree-ecology-leaf-detail-sheet-v1.png`

The common-scale contact sheet shows monotonic height, girth, branch, terminal, and crown growth beside a house-height reference. The detail sheet shows individual attached leaf cards rather than solid crown blobs.

Final build command:

```powershell
.\tools\blender\build-environment-assets.ps1 -SkipGenerate
```

Results:

- Blender re-import: 69/69 assets valid.
- Node manifest validator: 69 assets valid under schema 3.
- Godot canopy import contract: 9/9; all 43 canopy GLBs imported.
- Static meshes only; no armature, skin, morph, or animation clip.
- Ecological fields, fullness, grounding, wind colors, bark UV0, triangle bounds, and monotonic growth all passed.

This phase changes asset capability only. Runtime publication is owned by VOX-130.
