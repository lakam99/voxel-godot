# N4 Feature-Footprint Prerequisites

## Scope

This milestone prepares the native backend to accept generated-feature
tombstones without inventing a second prop, collision, render, or navigation
authority. It is a prerequisite, not a tombstone cutover.

The implementation adds an immutable, source-bound
`NativeGeneratedFeatureFootprintCatalog`. Each opaque generated feature ID is
bound to its recipe revision, definition digest, and canonical X-runs for the
terrain-source, render, collision, and navigation channels. The catalog is a
derived index: it does not generate props, choose a visual, or publish a
collision body.

The milestone also corrects two save-boundary translations:

- aggregate `terrainVolume` is a typed `NativeTerrainVolumeV2`, not an
  unbounded `NativeValue`;
- independent terrain, tombstone, and player-instance capacities retain their
  own production limits and use subtraction-safe total admission;
- omitted legacy-within-v2 player-block fields use the same defaults as
  `MainSaveState.gd`, including `worldY = cell.y * 1.35`, `facing = 0`, empty
  slots, and furnace duration `4.5`.

Door group IDs that depend on live neighboring blocks remain a
publication-time decision. The codec does not guess a facing-only identity.

## Catalog-backed tombstone admission

`WorldDeltaStore` now accepts a nonempty tombstone only when its immutable
catalog resolves every stable ID. It derives one deduplicated, bounded section
receipt from each changed feature's terrain-source, render, collision, and
navigation runs. Replacing a tombstone invalidates both the old and new
footprints; restoring a feature invalidates the removed footprint. Unchanged
tombstones do not trigger spurious publication work.

The catalog is fixed for the store lifetime. Its source digest, feature-source
revision, and content digest are bound into feature transaction identity. The
receipt has a 262,144-section production cap; oversize removal is rejected
atomically rather than silently truncating invalidation.

## Deliberately retained boundary

No production feature family generates this catalog yet, and no Godot
publication consumer receives the new receipt. Therefore the production
`removedProps` path remains unchanged and is not a cutover claim. The next
N4 feature-family slices must build source-bound entries from deterministic
tree/prop/structure/citadel recipes and consume the receipt in terrain,
render, collision, and navigation publication before a live tombstone can be
accepted.

No Godot production caller, terrain publication path, NPC route/motor/door
code, or save envelope was changed in this milestone.

## Verification

`node tools/run-native-world-backend-tests.mjs --run-name n4-shadow-prerequisites-06`

The receipt is
`artifacts/native-world-backend/n4-shadow-prerequisites-06/report.json`:

- debug standalone core: 275/275;
- release standalone core: 275/275;
- Godot 4.6.1 adapter smoke and isolated staged release-export save-adapter
  smoke: passed;
- strict pure-core coverage: 6,343/6,343 lines, 820/820 functions, and
  3,238/3,238 branches.

This verifies native value semantics and the shadow adapter boundary. It does
not claim full `removedProps` import, live Continue, collision cutover, or NPC
acceptance.

Catalog-backed tombstone admission was then verified with:

`node tools/run-native-world-backend-tests.mjs --run-name n4-catalog-tombstone-admission-03`

That receipt passed 278/278 debug and 278/278 release tests with 6,412/6,412
lines, 823/823 functions, and 3,272/3,272 branches. It proves the isolated
native admission/invalidation contract only; it does not prove generated
catalog construction or live publication.
