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

## First source-producer boundary

The first native feature producer must be the complete deterministic
28-attempt surface-prop manifest for one chunk, not a tree-only implementation.
The live source seeds one shared RNG with `hash_string("%s:props:%d,%d")`,
constructs durable IDs as `seed:x,z:attempt`, and lets trees, rocks, ore,
forage, and wildlife consume that common stream. A tombstone lookup currently
happens after the coordinate draws but before later attempt draws; copying that
order would make a removed prop reshuffle unrelated future props. The native
producer must instead derive the unfiltered baseline manifest, then apply
tombstones only to publication.

Tree records need both the durable removal ID and the distinct recipe identity
when a Citadel request supplies one. Their typed definition must include the
runtime request's height, trunk radius, canopy radius, collision height,
exclusion margin, placement, and the single upright trunk cylinder contract.
The footprint catalog references that definition through its digest; it does
not replace typed feature geometry.

`NativeTreeDefinition` now records that fact as an immutable NTD1 value. It
keeps natural world placement distinct from site-owner-local placement, retains
the owner ID needed to rebind a Citadel tree, and never derives one opaque ID
from the other. Its exact physical declaration is one float32 trunk cylinder
(`radius = trunkRadius`, `height = collisionHeight`, centered at half height).
Canopy and ordered root-buttress records are non-collision provenance; a
natural surface tree cannot carry buttresses, while a site tree may. This is a
definition/digest boundary only: it neither chooses a tree nor publishes one.

Underground props are a separate source/RNG domain and are explicitly outside
this first surface-manifest slice. Native compatibility tests must also cover
Godot Unicode-scalar hashing and `RandomNumberGenerator` semantics before
claiming raw-seed or non-ASCII stable-ID parity.

## Surface-prop RNG compatibility slice

`GodotPcg32` now implements the pinned Godot 4.6 PCG seed, bounded-range,
state, and single-precision `randf` semantics in the pure core. The companion
`NativeSurfacePropAttemptStream` creates the unfiltered 28 coordinate/opaque-ID
attempts for one surface chunk. It validates raw UTF-8/scalar agreement and
rejects out-of-domain chunk coordinates; it does not query terrain, choose a
feature class, calculate ecology, or publish anything.

The headless `N4SurfacePropRngOracle.gd` records Godot's raw/range/float state
vectors and ASCII plus non-ASCII chunk attempts. The native tests freeze those
engine vectors and cover PCG rejection/float edge paths, Unicode scalars,
negative chunks, and malformed admission. This is deliberately a compatibility
prerequisite: no production prop recipe or `removedProps` authority changed.

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

The surface-prop RNG/attempt-stream slice was verified with:

`node tools/run-native-world-backend-tests.mjs --run-name n4-prop-rng-attempt-stream-08`

Its receipt is
`artifacts/native-world-backend/n4-prop-rng-attempt-stream-08/report.json`:

- debug and release standalone core suites passed;
- Godot 4.6.1 adapter smoke and staged release-adapter smoke passed;
- strict pure-core coverage: 6,515/6,515 lines, 842/842 functions, and
  3,296/3,296 branches.

The engine oracle was captured at
`artifacts/native-world-backend/n4-prop-rng-attempt-stream-07/godot-rng-oracle-report.json`.
Together these prove source-RNG/coordinate compatibility in isolation, not
terrain/feature-class parity, typed feature geometry, tombstone publication,
or live gameplay.

The typed tree-definition contract was verified with:

`node tools/run-native-world-backend-tests.mjs --run-name n4-tree-definition-contract-03`

Its receipt is
`artifacts/native-world-backend/n4-tree-definition-contract-03/report.json`:

- debug and release standalone core suites passed 293/293 tests each;
- Godot 4.6.1 adapter and staged release-adapter smokes passed;
- strict pure-core coverage: 6,670/6,670 lines, 882/882 functions, and
  3,586/3,586 branches.

This proves canonical native tree-definition admission, identity, coordinate
frames, and the physical/non-collision boundary. It does not prove native
ecology/recipe generation, a catalog producer, rendering/collision publication,
tombstone behavior, or live gameplay.

## Surface-prop shared-RNG trace

`NativeSurfacePropRngTrace` is the next shadow-only producer boundary. It
replays all 28 coordinate draws from the immutable attempt stream and accepts
an externally supplied, source-authoritative replay receipt for every attempt.
It records the exact post-coordinate, post-class-roll, and post-recipe PCG
states plus the legacy ordinary-rock/tree compatibility values. Structure or
terrain/profile decisions remain outside the core until their authoritative
receipts are typed and supplied by the native source; no terrain or profile
logic is copied into this value.

The replay trace is a witness for supplied dispositions, not a classifier. In
particular, an `ordinary_rock` receipt is valid only when the source has already
established that `ore_for_cell` returned empty. It must never stand in for an
ore-window rock: live Godot consumes an extra ore roll there and a selected ore
cluster has its own child recipe stream. There is deliberately no tombstone
argument; a later producer must generate this complete baseline first and only
then let parent/child removal filter publication.

`node tools/run-native-world-backend-tests.mjs --run-name n4-surface-prop-rng-trace-01`
passed 296/296 debug and release core tests, both adapter smokes, and strict
pure-core coverage of 6,718/6,718 lines, 890/890 functions, and 3,618/3,618
branches. Its receipt is
`artifacts/native-world-backend/n4-surface-prop-rng-trace-01/report.json`.

This is shared-RNG compatibility evidence only. It does not classify a live
surface, generate a native feature definition, publish a feature, accept a
live tombstone, or establish gameplay parity.

The trace now also requires an opaque source receipt with a schema revision,
terrain revision/digest, and environment-profile revision/digest. The future
adapter must capture those identities from the same admitted generated- or
edited-volume surface projection and profile snapshot that chose every attempt
receipt. This prevents stale surface/profile facts from being replayed as a
current feature baseline without putting a second terrain sampler or catalog
into the trace core.

`node tools/run-native-world-backend-tests.mjs --run-name n4-surface-prop-source-receipt-02`
passed 296/296 debug and release core tests, both adapter smokes, and strict
pure-core coverage of 6,732/6,732 lines, 893/893 functions, and 3,634/3,634
branches. Its receipt is
`artifacts/native-world-backend/n4-surface-prop-source-receipt-02/report.json`.

The trace is now a canonical `SPT1` immutable artifact. Its SHA-256 content
digest covers the source receipt, every attempt's replay disposition, all PCG
state boundaries, class roll, compatibility values, and final state. This is
the identity a future generated-feature catalog may reference; changing the
terrain/profile receipt or any decision cannot reuse the prior trace digest.

`node tools/run-native-world-backend-tests.mjs --run-name n4-surface-prop-trace-identity-01`
passed 296/296 debug and release core tests, both adapter smokes, and strict
pure-core coverage of 6,772/6,772 lines, 902/902 functions, and 3,644/3,644
branches. Its receipt is
`artifacts/native-world-backend/n4-surface-prop-trace-identity-01/report.json`.

## Typed surface classification receipt

`NativeSurfacePropClassifier` is the next pure-core boundary. It accepts one
Godot-authored, source-bound receipt per immutable attempt and verifies the
ordinal/cell binding before it compares exact float32 cumulative cutoffs with
the exact Godot PCG rolls. The receipt carries only source facts: structured
admission (`structure_blocked`, unavailable/ineligible surface, town, or
eligible), a nonzero decision digest, cumulative placement cutoffs, the legacy
tree compatibility family, and the precomputed ore policy/cutoffs. It does not
sample terrain, call the environment catalog, recompute height or biome bias,
or know about tombstones.

This deliberately preserves live priority semantics, including totals above
one and strict cutoff equality. It also exposes ore as a separate consumed
roll: iron/copper cluster outcomes are explicitly **unported**, not ordinary
rocks. Forage and wildlife are likewise explicit unported outcomes until their
complete recipe/asset contracts are native. Therefore this classifier cannot
yet feed a completed trace or generated-feature catalog; it is a fail-closed
decision boundary, not a feature-family cutover.

## Ore and forage follow-on boundaries

`NativeOreClusterStream` now captures the complete two-child shared-PCG
baseline used by the live surface source. It records child IDs and state
boundaries, consumes 47 float draws plus the bounded drop draw for child zero,
and 48 plus the bounded draw for child one (the latter has the extra spacing
draw). It has no tombstone parameter. The current script-side child removal
check is therefore documented as a stream-order defect, not an intended source
rule to carry into native generation.

Forage remains unported. Its native admission must replace the current
profile/default visual fallback with a typed recipe registry: stable recipe,
material and drop IDs; inclusive yield range; positive collider radius;
recognized visual grammar; and explicit navigation policy. The initial native
recipe stream must preserve the current branch draw order (berry 26, aloe 44,
mushroom 26, frost herb 37 recipe calls) even when its root is later removed.
Any isolated per-feature RNG redesign requires an explicit generator-version
and world-signature migration rather than an implicit compatibility change.

## Wildlife follow-on boundary

Wildlife remains unported.  Its surface attempt is not representable as a
generic count of random draws: after the classifier has selected wildlife,
the live source consumes a typed sequence of a profile `randf`, yaw `randf`,
two inclusive bounded yield ranges, a presentation branch, then direction,
timer, and speed random values.  `randf` itself has Godot's two-raw-PCG-output
ordinary path (and a rare one-output zero path), while each bounded range can
consume an additional raw output through rejection.  A native compatibility
stream must therefore replay the actual operation types and assert the
pre/post-PCG state; it must not substitute nine generic float draws.

The presentation branch is a real source dependency.  Procedural fallback
uses two visual floats; an instantiated animated visual with a playable
AnimationPlayer/clip uses scale and animation-speed floats; the legacy
instantiated-but-no-player path uses only the scale float.  The latter is an
asset-readiness accident, not a valid native authority.  Native admission must
receive a source-bound presentation capability receipt that identifies the
selected boar/deer/hare variant, canonical asset and clip IDs, the actual
asset-catalog content digest, and whether the animation capability is
playable.  It must admit only a deliberate procedural fallback or a complete
animated capability, reserve the two presentation operations in either case,
and reject partial asset/player states rather than preserving an eight-draw
branch.

`NativeWildlifePresentationReceipt` now supplies that narrow, source-bound
capability value.  It requires a nonzero schema revision and catalog content
digest, a typed boar/deer/hare variant, that variant's exact current asset and
clip IDs, and either `procedural_fallback` or `animated_playable`.  There is no
native representation for an instantiated visual without a playable player or
clip.  The eventual adapter must turn that legacy partial capability into an
explicit fallback before it reaches native generation.

`node tools/run-native-world-backend-tests.mjs --run-name
n4-wildlife-presentation-receipt-03` passed the standalone debug/release core
suites, both adapter smokes, and strict pure-core coverage of 6,927/6,927
lines, 934/934 functions, and 3,862/3,862 branches.  Its receipt is
`artifacts/native-world-backend/n4-wildlife-presentation-receipt-03/report.json`.
This proves only capability-receipt admission; it does not yet establish a
native wildlife profile, RNG stream, feature definition, publication, or live
gameplay parity.

The eventual wildlife definition must preserve the selected profile's collider
dimensions/center, yield ranges, cold and speed semantics, and current
navigation classification.  Present wildlife is a transform-driven
`StaticBody3D` that the navigation adapter treats as a static prop blocker; it
is not yet a native terrain collider or a declared dynamic actor.  Changing
that classification is a separate gameplay/product decision, not a migration
translation.  Like every surface feature, native generation must first produce
the full baseline recipe stream and only then apply durable `removedProps` as
a publication filter.
