# VOX-129 Scale-Safe Bark Report

## Outcome

Generated trunks and branches now carry branch-aligned UV0 and use the existing shared tree wind shader as a bounded procedural bark material. Tall/elongated segments gain bark repeats instead of stretching a single blurred patch. No tree receives a unique material.

## Coordinate and material contract

- U wraps each authored segment circumference with one bounded seam.
- V is based on physical segment length at 0.72 repeats per metre before joining.
- Coordinates survive GLB export/import and are validated for finite values and repeat density.
- The shared shader uses U-oriented irregular furrows and fine grain; branches retain longitudinal grain regardless of world orientation.
- Instance `bark_scale` compensates modest runtime scale without duplicating the cached material.
- Bark uses mesh UVs and the existing vertex deformation, so it remains attached during calm/storm wind, shadows, and the falling-tree transform.
- Root wind weights remain fixed.

## Evidence

The Blender validator and Godot import contract prove UV0 presence for every ecological trunk/branch and enforce the bark manifest fields. The runtime contract proves the shared shader consumes UV and instance scale rather than world-space mapping or per-tree materials.

`tools/run-environment-wind-contract-tests.ps1 -ReportPath artifacts/vegetation/vox131-environment-wind-final.json`

- 11/11 passed.
- Exactly five shared shader-global writes per update.
- Cached shared tree materials and finite ecological families.
- CPU update p99 remains below 1 ms.

`tools/run-environment-wind-visual-playtest.ps1 -ReportPath artifacts/vegetation/vox131-environment-wind-visual-final.json`

- 8/8 headed Forward+ checks passed.
- Calm/storm silhouettes differ, two storm instants are asynchronous, daylight shadow patterns move, roots remain fixed, and the torch-lit night crown remains readable.
- Manual inspection confirms vertical irregular trunk grain after the final shader change; no horizontal banding or world-space swimming was observed.

Material architecture remains within the completed VOX-121 shared GPU wind system. This phase adds no CPU tree animation and no pathfinding/town behavior.
