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
| Rocks | Source-ordered typed sphere and visual asset selection exist. The six active `rock_*.glb` files carry precise POSITION accessor bounds, and direct Godot import AABBs match within one float32 ULP. The pure-core `native_surface_rock_footprint` projects selected-import or primitive-fallback render bounds after the runtime Y/Z-swapped scale policy, plus the typed sphere collision/navigation runs. A source-matched core test checks every cell in six renderer-capable Godot scaled-mesh AABBs and one primitive-fallback AABB at negative anchors against the production-used native projection, with the exact GLB SHA-256 values in its fixture. Adapter visual admission now checks each manifest GLB hash against the on-disk file and retains its exact bounds under the selected catalog digest. | Source-matched adapter contract must pass with actual GLB bytes and reject a coherent stale-hash recapture. Actual generated-asset versus primitive-fallback publication outcome remains unbound; aggregate transition, headed removal/save proof and cutover remain open. Do not treat the verified file receipt alone as complete authority. |
| Trees | [`NativeTreeArtifact`](N4_TREE_ARTIFACT_SHADOW_2026-09-24.md) binds native Norway-spruce and umbrella-thorn worker recipes to immutable/revisioned source identity, tier-specific branch/foliage/impostor render input, bounds and the exact definition-owned trunk cylinder. Primary `75fbd73` adds umbrella-thorn pure-core recipe/artifact support; focused candidate MSVC and LLVM tests pass 11/11, and the source manifest discovers and declares 219/219 core/test files. Broadleaf/oak remains pending. A later independent review made Savanna shadow promotion NO-GO: finite but extreme dimensions such as `DBL_MAX` can narrow to non-finite generated geometry while the recipe remains valid; there are no extreme-finite regression tests or post-adaptation finite-output invariant. Its GDScript oracle sources also lack a registered source-bound differential runner, and topology booleans need independent graph-completeness checks. | Fix and test bounded geometry validity, register a source-bound differential runner, and independently prove topology invariants before promoting Savanna shadow. Complete broadleaf/oak, then bind artifacts through one Godot consumer to live visual publication and trunk physics. PoC/runtime parity, headed visual/collision proof, durable removal/save/reload and production cutover remain open. Preserve the generated-asset and tree-publication presentation pipeline. |
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

The read-only `tools/derive-n4-rock-glb-bounds.mjs` now extracts exact vertex
bounds from each active rock GLB and verifies its single-node identity scene
transform. Its receipt records the visual manifest and each GLB SHA-256. This
establishes asset-source facts only; Godot import transforms, active asset
selection, fallback outcome and live publication still require admission.
