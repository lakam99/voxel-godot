# N4 surface feature manifest shadow checkpoint

`NativeSurfaceFeatureManifest` composes one source-bound, 28-attempt ordinary
surface-prop chunk from the existing ordered stream, checked placement set,
effective terrain, biome/rock/wildlife catalogs, structure exclusions and
post-draw tree halo. Each immutable entry retains its placement, tombstone and
RNG suffix and the applicable typed rock, ore, forage, wildlife or tree
definition. Trees separately retain their exclusion-halo presence decision:
an anchored placement is not permission to publish a blocked tree.

The Godot adapter's `compose_surface_tree_presence_shadow` now constructs this
whole-chunk manifest after admitting the exact tree-request union and halo,
then returns its digest alongside the tree decisions. The earlier ordered
shadow still supplies the post-draw halo requests. Both adapter receipts
remain explicitly `completeFeatureManifest=false` and
`liveCaptureFreshnessProven=false`. This is not a production scene, collision,
navigation, save or tombstone-footprint authority.

## Verification

- `node tools/run-native-world-backend-tests.mjs --run-name n4-surface-feature-manifest-03`:
  `artifacts/native-world-backend/n4-surface-feature-manifest-03/report.json`
  passed 454/454 debug and 454/454 release core tests, editor adapter and
  isolated release-adapter smokes, with validated pure-core coverage of
  10,141/10,141 lines, 1,393/1,393 functions and 6,034/6,034 branches.
- `node tools/run-n4-direct-source-order-differential.mjs`:
  `artifacts/native-world-backend/n4-direct-source-order-differential/report-998ae71c-a6ce-4ac5-9066-997d56d06dae.json`
  passed on that installed build. Six direct-service cases compare 39 forage,
  2 ore-cluster, 6 wildlife, 11 rock and 45 tree definitions; 44 direct tree
  bodies and one outside-chunk natural exclusion are covered. Each admitted
  tree-halo case now requires a 64-hex whole-manifest digest.

The focused unit suite covers negative chunks, all outcome constructors,
parent and ore-child tombstone RNG shifts, blocked tree presence, stale
source/catalog/structure/halo bindings and a same-content/different-owner
structure generation. The last distinction matters: SES1 content identity
does not include world generation, so generation is checked independently.

Independent read-only review found no concrete correctness defect in this
shadow scope. Constructor-implied checks were removed, while independent
source-binding checks remain. The direct-service fixture did not exercise a
keyed-absent Citadel halo row, and neither it nor the digest establishes a
live owner-fresh publication or headed gameplay parity.

## Cutover boundary

No normal gameplay caller consumes this manifest. Before N4 production
publication, the adapter must prove live owner freshness, retain the exact
union/halo admission, combine placement with tree presence, provide final
family geometry and all-channel footprints, and atomically publish a full
source-ordered chunk. `WorldDeltaStore` cannot use this as its generated
feature footprint catalog. The existing GDScript source and presentation
remain production authorities; N3/N4 cutover and Gate 5 remain open.
