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

## Deliberately retained boundary

`WorldDeltaStore` still rejects nonempty feature tombstones. A catalog entry is
not yet sufficient acceptance evidence: the removal must yield a complete
source/revision-bound invalidation receipt, which must then be consumed by
terrain, render, collision, and navigation publication. Permitting the save
record before that path exists would let a removed prop reappear or leave
stale physical/navigation artifacts.

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
