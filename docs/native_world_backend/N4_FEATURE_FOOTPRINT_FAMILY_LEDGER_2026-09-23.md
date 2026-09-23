# N4 generated-feature footprint family ledger

Status: **partial pure-core migration; no production cutover or deletion**.
This ledger tracks the source that owns each family's visual and physical
geometry, and the evidence still needed before a durable removal can publish
through the one native world-delta journal. A declared channel mask on one
family does not prove that a chunk transition has complete footprints.

| Family | Typed source and footprint status | Remaining acceptance/deletion gate |
| --- | --- | --- |
| Ore clusters | `NativeSurfaceOreClusterDefinition` supplies two child IDs, procedural stone/seam/glint geometry and sphere colliders. `native_surface_ore_footprint` derives bounded render, collision and navigation cell runs; terrain-source has no runs because node removal does not edit volume. Pure-core tests cover child removal, conservative rotated geometry, negative cells and limits. | Direct Godot transformed-mesh/collider oracle, before/after aggregate catalog and atomic journal admission, headed removal/save/reload. Retain `make_ore` until publication consumes the same typed artifact. |
| Forage | `NativeSurfaceForageOrderedDefinition` supplies four procedural grammars, sphere collider and independent navigation policy. `native_surface_forage_footprint` derives render/collision runs and navigation runs only for blocking recipes, using the shared bounded quantizer. The direct Godot constructor oracle records every transformed child-mesh and sphere-collider world AABB at four positive/negative locations; a native core test checks that every recorded AABB cell belongs to the matching native channel run. | Aggregate transition and headed interaction/save proof. The AABB comparison proves conservative constructor-footprint containment for those four seeds, not live publication or arbitrary seeds. Retain `make_forage` and its material/interaction presentation until cutover. |
| Rocks | Source-ordered typed sphere and visual asset selection exist; no complete source-bound footprint. The six active `rock_*.glb` files carry precise POSITION accessor bounds; `visual-manifest.json` carries rounded Blender-axis `boundingBox` and grounded pivot metadata. Runtime applies a Y/Z-swapped size normalization and can choose primitive fallback if the selected scene does not instantiate. | Admit a source-bound receipt for exact imported mesh bounds and pivot, tied to the active asset catalog and the selected generated-asset versus primitive-fallback outcome. Derive render cells after the runtime scale/axis transform; retain the typed sphere for collision. Verify against direct Godot scene and collider AABBs, then removal/save proof. Do not treat rounded manifest size alone as a complete render bound. |
| Trees | Typed ecology/recipe, presence and trunk cylinder exist; no complete source-bound render/support footprint. | Bound the actual family grammar canopy/branch geometry and trunk blocker from the same recipe; PoC/runtime and headed visual/collision oracle. Preserve Blender/generated asset and tree publication pipeline. |
| Wildlife | Typed initial box and presentation receipt exist; no motion-wide footprint. | Animated asset bounds and moving-body lifecycle need a source-bound policy; coordinate physical ingress with N5. Direct/live Godot collider oracle, motion/reload proof. |
| Generated buildings/Citadel | Script recipes and structural manifests remain production source; native exclusion snapshots are partial input only. | Port immutable recipe, exact shapes/support, doors/stairs/porches and manifest ownership by coherent family, with physical/nav and headed town/Citadel checks. No pathfinding internals may change under N4. |

## Transition and journal gate

`NativeSurfacePropChunkTransition` currently names changed ordinals/IDs and
before/after typed manifests but intentionally reports
`CHANNEL_FOOTPRINTS_COMPLETE=false`. A future complete packet must bind both
before and after physical source digests, the current global
`WorldDeltaStore` revision, feature snapshot identity, and every changed
durable ID to an explicit present footprint or absent state. It must reject an
unknown family or incomplete channel atomically. One native journal commit
must return the union of changed render/collision/navigation/support sections
and advance the same global revision consumed by N3 terrain pins and N6 nav
tiles. The constructor-fixed catalog cannot certify an RNG-shifted suffix
whose after-state contains new IDs. No current N4 family producer is wired to
the journal or gameplay, and no script deletion is authorized.
