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
forage, and wildlife consume that common stream. A parent tombstone lookup
happens after the coordinate draws but before later attempt draws, so a removed
prop changes later coordinates in the existing save replay. The native producer
must preserve that source order during migration. A non-perturbing removal
policy would require a separately versioned gameplay/save decision.

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
cluster has its own child recipe stream. This diagnostic trace deliberately
has no tombstone argument. It is an intact-stream witness, not a production
source-order authority for replaying removed parents or ore children.

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
ordinal/cell binding before it compares Godot float64 cumulative cutoffs with
the exact float32 Godot PCG rolls (promoted for comparison). The receipt carries only source facts: structured
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

Forage and wildlife now have typed native recipe streams, so their classifier
outcomes are `forage_recipe` and `wildlife_recipe`, not stale `unported_*`
labels.  That is deliberately not a claim of complete surface generation:
the classifier still requires a future aggregate composer to supply the typed
recipe-stream input and produce one baseline manifest.  `node
tools/run-native-world-backend-tests.mjs --run-name
n4-surface-prop-recipe-admission-01` passed 317/317 debug and release core
tests, both adapter smokes, and strict coverage of 7,013/7,013 lines,
942/942 functions, and 3,900/3,900 branches.  Its receipt is
`artifacts/native-world-backend/n4-surface-prop-recipe-admission-01/report.json`.

## Ore and forage follow-on boundaries

`NativeOreClusterStream` first captured the intact two-child shared-PCG
baseline used by the live surface source. It records child IDs and state
boundaries, consumes 47 float draws plus the bounded drop draw for child zero,
and 48 plus the bounded draw for child one (the latter has the extra spacing
draw). The later tombstone-aware overload skips a removed child before its
recipe draws, matching existing save replay. The intact overload remains a
shadow diagnostic; neither overload independently owns the shared 28-attempt
stream.

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
This proves only capability-receipt admission; it does not itself establish a
native feature definition, publication, or live gameplay parity.

`NativeWildlifeRecipeCatalog` now owns the immutable current boar/deer/hare
profile facts: wildlife/raw-meat/hide IDs and inclusive yields, visual and
speed multipliers, cold multiplier, exact box-collider dimensions/center,
default collision layer/mask, and static-prop navigation policy.  Biome/cold
selection is intentionally not duplicated there; it remains a future typed
source receipt.  `node tools/run-native-world-backend-tests.mjs --run-name
n4-wildlife-recipe-catalog-01` passed 312/312 debug and release core tests,
both adapter smokes, and strict coverage of 6,957/6,957 lines, 937/937
functions, and 3,870/3,870 branches.  Its receipt is
`artifacts/native-world-backend/n4-wildlife-recipe-catalog-01/report.json`.

`NativeWildlifeProfileSelector` ports the current biome-group thresholds with
strict cutoff equality, and `NativeWildlifeStream` replays the complete typed
shared-PCG sequence: profile, yaw, inclusive primary/extra yields, two
reserved presentation operations, direction, timer, and speed. The stream
validates the source presentation receipt before it touches PCG, probes the
same next profile roll to reject a variant mismatch without mutating the live
stream, then records pre/post state and every typed result. A cold group is
the only source of the current cold speed state. `node
tools/run-native-world-backend-tests.mjs --run-name n4-wildlife-stream-01`
passed 317/317 debug and release core tests, both adapter smokes, and strict
coverage of 7,013/7,013 lines, 942/942 functions, and 3,900/3,900 branches.
Its receipt is `artifacts/native-world-backend/n4-wildlife-stream-01/report.json`.
This is still a shadow-only stream contract: no live feature manifest,
tombstone filtering, GDScript caller deletion, or gameplay cutover has
occurred.

The eventual wildlife definition must preserve the selected profile's collider
dimensions/center, yield ranges, cold and speed semantics, and current
navigation classification.  Present wildlife is a transform-driven
`StaticBody3D` that the navigation adapter treats as a static prop blocker; it
is not yet a native terrain collider or a declared dynamic actor.  Changing
that classification is a separate gameplay/product decision, not a migration
translation. Native generation must preserve the live tombstone checkpoints
before wildlife recipe selection and later shared-PCG draws.

## Complete typed surface baseline stream

`NativeSurfacePropBaselineStream` now composes one unfiltered 28-attempt
shared-PCG baseline from the immutable attempt stream and one source-bound
classification receipt per attempt. It replays coordinate draws, admission
and class/ore rolls, legacy rock/tree compatibility draws, the two-child ore
stream, typed forage stream, and typed wildlife stream in source order. Each
entry records its PCG boundaries and typed child stream. The composer first
dry-runs against a cloned PCG state, so malformed source/recipe receipts leave
the caller's visible replay path unmodified.

This historical shadow stream is deliberately not a physical feature manifest.
It does not contain
world placement, geometry, visual asset selection, collision installation,
navigation publication, tombstone filtering, or a Godot caller cutover. The
next N4 slice must attach those facts as one typed feature definition and then
derive footprint-catalog entries from that definition. Its unfiltered replay
cannot substitute for the later source-ordered producer when tombstones are
present; that producer must preserve the live parent and ore-child skip points.

`node tools/run-native-world-backend-tests.mjs --run-name
n4-surface-prop-baseline-stream-03` passed 320/320 debug and release core
tests, both adapter smokes, and strict pure-core coverage of 7,113/7,113
lines, 952/952 functions, and 3,956/3,956 branches. Its receipt is
`artifacts/native-world-backend/n4-surface-prop-baseline-stream-03/report.json`.
The test suite includes every typed family, missing/ambiguous recipe receipts,
source-classifier rejection, and a focused corrupt-enum invariant guard. It
does not establish live surface/feature parity or gameplay acceptance.

The tree compatibility names are now checked against direct Godot execution,
not a source-text count: the center clump's literal zero spread consumes no
PCG draw, so the live totals remain 36 for broadleaf and 22 for conifer.
`node tools/run-surface-prop-tree-rng-contract.mjs --report-path
artifacts/native-world-backend/n4-surface-prop-pcg-parity-02/godot-tree-rng-report.json`
passed all three direct consumer cases. This is a source/RNG contract only,
not feature-geometry, publication, or gameplay evidence.

## Canonical surface placement receipt

**2026-09-22 source audit correction:** The SPP1 air-cell lattice anchor
described below is not the live surface-prop body height on unedited ground.
`MainPlaytestTools.spawn_chunk_prop_attempt` uses the continuous
`surface_volume_spawn_sample_at_cell.height`, which normally comes from
`WorldGenerationSystem.volume_surface_y_for_cell`'s numeric-density boundary
interpolation. Only the surface-affecting edited-volume projection returns
`airCell.y * CELL`. Thus SPP1 and its passing synthetic tests are a shadow
placement witness, not physical placement parity or a cutover-ready authority.
The shared placement set must be revised to consume a pinned native surface
spawn projection, carry its continuous height and full effective-source
identity, and reject stale source/profile receipts before any feature family
publishes geometry or collision. Existing tree/rock definitions built on SPP1
must be reverified after that correction.
The source decision digest and environment-profile identity must also be
checked against the same admitted projection/profile snapshot; nonzero bytes
alone do not establish currentness. `make_rock` recomputes its visual biome
from the body position, so classification and presentation biome must not be
silently conflated. Neither an SPP2 digest nor a passing pure-core test alone
proves live collision publication or tombstone lifecycle.

The following SPP1 checkpoint is historical and superseded by SPP2.
`NativeSurfacePropPlacementSet` was the first bridge from the complete
baseline stream to future typed physical definitions. It binds every one of
the 28 ordered baseline entries to its durable ID, source-decision digest,
source receipt, and immutable `WorldSourceDefinition` identity. A selected
feature must carry an authoritative solid/air surface pair at the candidate's
same X/Z lattice coordinate; the pair must be adjacent and its canonical world
anchor is resolved as the existing gameplay lattice query at the air cell.
Its lattice Y was subsequently found not to be the live unedited prop height;
the SPP2 projection below replaces that claim.

Skipped and no-feature outcomes explicitly have no physical anchor. All typed
feature outcomes (rocks, trees, ore clusters, forage, and wildlife) require
one. SPP1 contains no renderer asset, collider shape, navigation declaration,
terrain sampling, material/biome policy, or tombstone input. Those facts remain
with each family definition and must be composed before a footprint-catalog
entry can be derived. This keeps source selection, physical geometry, and
publication filtering as distinct authorities.

`node tools/run-native-world-backend-tests.mjs --run-name
n4-surface-prop-placement-set-04` passed both debug and release core suites,
both adapter smokes, and strict pure-core coverage of 7,249/7,249 lines,
974/974 functions, and 4,056/4,056 branches. Its receipt is
`artifacts/native-world-backend/n4-surface-prop-placement-set-04/report.json`.

## Natural-tree source-semantics guard

Before the native natural-tree definition can become a physical feature
definition, its seed handling must preserve the two source operations exactly.
`TreeRuntimeRequestBuilder.select_tree_family` hashes the raw `seed_text`,
while `TreeEcologySampler.sample_tree` trims that seed and substitutes
`"default"` when it is empty. These are deliberately distinct inputs even
when the current two-family plains profile maps a particular raw and trimmed
pair to the same selected family.

Normal gameplay already trims an entered seed in `MainCore.apply_world_seed`
before a world source is created, so this is not evidence of a current
player-visible whitespace-seed regression. It remains a source-helper and
adapter boundary that native code must preserve rather than collapsing through
an incidental normalization.

`node tools/run-surface-tree-seed-semantics-contract.mjs -ReportPath
artifacts/native-world-backend/n4-surface-tree-seed-semantics-03/godot-seed-semantics-report.json`
directly executed both source paths and passed its whitespace and empty-seed
fixtures. The semantic fixture uses a wider family list solely to make the raw
hash distinction observable; the actual plains profile remains the authority
for the constructed ecology request. This is source-contract evidence, not
native parity, physical publication, or gameplay acceptance.

## Native natural-tree definition composer

`NativeSurfaceTreeDefinitionComposer` was first verified against one anchored SPP1 tree
placement, its matching unfiltered baseline entry, immutable world-source
identity, and a typed ecology profile. It deterministically chooses the source
family from the raw seed, derives ecology from the normalized seed, records the
runtime height/canopy/trunk/collision request, and emits the existing canonical
single-upright-trunk `NativeTreeDefinition`. It rejects mismatched replay,
identity, anchor, profile, family/outcome, and compatibility-draw facts before
constructing that definition. The profile's finite/range requirements and
source age-window repair are covered explicitly.

`node tools/run-native-world-backend-tests.mjs --run-name
n4-surface-tree-definition-composer-06` passed 332/332 standalone core tests
in each debug and release configuration, both Godot adapter smokes, and strict
pure-core coverage of 7,480/7,480 lines, 1,003/1,003 functions, and
4,262/4,262 branches. Its receipt is
`artifacts/native-world-backend/n4-surface-tree-definition-composer-06/report.json`.

This is a pure, source-bound recipe and physical-declaration slice only. It
does not yet compose rocks, ore, forage, or wildlife into the one ordered
baseline feature manifest; publish geometry/collision/navigation; filter
tombstones; or cut any Godot production caller over. Those remain aggregate
N4 and later publication work.

## SPP2 pinned surface projection and ordinary-rock correction

SPP2 supersedes the SPP1 physical anchor. A pinned
`NativeEffectiveTerrainSource` now supplies the surface-prop spawn facts from
the same effective terrain revision as the placement set. Unedited columns
use the continuous numeric-density boundary (including the Godot `Vector3`
float32 density boundary); projection-affecting edited columns use the
air-cell top and material/fluid checks. The edited-column decision sees both
durable and transient typed edits, with overlay precedence, through an
immutable per-column index. Query work is proportional to records in the
column rather than all saved edits. Rebuilding that index on an effective
transaction still costs O(N log N), so edit-throughput profiling remains a
production-cutover task.

The SPP2 receipt binds the full effective-source digest, terrain-delta and
shaping revisions, and explicit environment-profile identity. Each of the 28
attempts retains its source height, support pair, biome/material and the
separately rounded chunk-origin/local-position operands. This matches the
Godot `Node3D` global-position float32 boundary, including positive and
negative chunk seams; multiplying an absolute X/Z cell directly is not
bit-equivalent. Missing support and stale pins reject rather than inventing
an anchor. The ordinary-rock native definition composes the source six-draw
recipe into typed visual scale and sphere-collision facts; the script source
recipe was extracted into `RockRecipeBuilder.gd` and remains the live path.

Direct Godot contract evidence (not live gameplay acceptance):

- `artifacts/native-world-backend/n4-surface-prop-spawn-oracle-02/report.json`
  passed exact unedited float32 Y vectors from
  `WorldGenerationSystem.volume_surface_y_for_cell`;
- `artifacts/native-world-backend/n4-surface-prop-chunk-transform-oracle-01/report.json`
  passed six exact `Node3D` origin/local/global X/Z bit vectors;
- `artifacts/native-world-backend/n4-surface-rock-recipe-oracle-06/godot-rock-recipe-report.json`
  passed four direct Godot rock-recipe sink cases.

`node tools/run-native-world-backend-tests.mjs --run-name
n4-surface-prop-spp2-rock-12` passed 352/352 debug and 352/352 release core
tests, the debug and isolated release-export adapter smokes, and strict
pure-core coverage of 7,874/7,874 lines, 1,050/1,050 functions, and
4,486/4,486 branches. Its receipt is
`artifacts/native-world-backend/n4-surface-prop-spp2-rock-12/report.json`.

This is still shadow-stage evidence. The baseline classifier accepts a
caller-supplied decision digest; no immutable native environment catalog or
structure-exclusion manifest yet derives and binds that decision from the
terrain pin. The tree composer also needs to enforce sampled-biome/profile
agreement. Ore child removals in the live source can alter subsequent shared
RNG draws, whereas the native stream currently represents an intact baseline.
Forage and wildlife builders likewise consume shared RNG for presentation
geometry. Those facts, full feature footprints and tombstone filtering,
production caller/deletion audits, live collision publication, and real
gameplay acceptance remain required before N4 or N3 cutover.

### Source-decision boundary after SPP2

The next producer must bind one admitted terrain pin, one resolved environment
catalog snapshot, and one immutable structure-exclusion snapshot before the
first of the 28 attempts. The live sequence waits for whole-chunk Citadel
terrain admission without consuming RNG, then draws each coordinate pair,
checks the durable removal ID and structure exclusion, samples effective
surface, applies height/town gates, and only then consumes the prop roll and
selected recipe draws. The native decision set must compute its own per-attempt
digest from those facts and exact scalar-height cutoffs; a caller-supplied
digest is insufficient. The source height must not be replaced by the rounded
`Vector3` anchor Y when calculating biome policy.
The catalog snapshot must retain scalar profile probabilities at Godot's
float64 `float` boundary; `rock_chance`, `tree_chance`, `forage_chance`, and
`wildlife_chance` are combined and compared in that precision. Narrowing the
cumulative cutoffs to float32 changes strict-boundary decisions. Packed detail and
tree-age arrays instead retain their loaded float32 elements. An oracle of
only displayed decimal values cannot prove these boundaries.
Legacy tree compatibility draw count is a separate input from ecology
architecture: `tree_visual_spec` consumes 22 draws only for `taiga`, `snow`,
and `tundra`, and 36 for all other tree biomes. `alpine.tres` declares a
conifer architecture but still takes the 36-draw legacy path. The current
native tree composer equates its conifer/broadleaf replay outcome with the
selected family architecture and would reject this valid alpine combination;
that is a migration mistranslation to correct before catalog-driven replay.
The current catalog audit found alpine is the only architecture/draw-count
mismatch: other conifer profiles (`taiga`, `snow`, `tundra`) use 22, while
plains/beach may select savanna or broadleaf but both use 36. The native
classifier's replay enum should describe draw compatibility only; the tree
composer must validate family and architecture independently against the
resolved profile. Extend the direct Godot tree RNG oracle across every
profile biome, including alpine, before asserting that separation is exact.
The coupling also appears in `NativeSurfacePropRngTrace` replay disposition,
not only the classifier, baseline stream, and tree composer. Correct the
typed replay schema through all four owners together, with a schema revision
and old-fixture audit. A composer-only alpine exception would leave the
shared-PCG state and durable trace semantically mislabeled.

**2026-09-22 correction implemented (shadow only):** Native classifier policy,
classification outcome, baseline stream, placement set, and RNG trace now name
the legacy tree consumer as a 36-draw or 22-draw replay mode, independent of
the selected ecology architecture. The tree composer checks that mode against
the source biome (`taiga`, `snow`, and `tundra` use 22; alpine and the remaining
biomes use 36), then selects visual architecture from the profile family.
Alpine conifer with 36 draws is a focused native test. Serialized placement
and RNG-trace receipts advance from SPP2/SPT2 to SPP3/SPT3; tree recipe
producer advances from STR1 to STR2. No v2 trace reader or fixture is retained:
old trace source receipts are rejected, and placement/tree definition fixtures
are rebuilt from current typed inputs. This changes shadow receipt identity,
not live Godot world/save format. Direct Godot source evidence is
`artifacts/native-world-backend/n4-tree-rng-all-profiles/report.json` (15/15
cases, including alpine); focused native debug evidence is
`artifacts/native-world-backend/n4-alpine-tree-replay-debug-04/test-debug.stdout.log`
(353/353 after the final type rename). Neither is gameplay or
production-cutover proof.

Structure exclusion currently spans natural-prop exclusion records, structure
terrain-footprint records, and ready/prepared Citadel reservations. The
`reserve_natural_prop_exclusion` path does not advance the regional source
revision, so that revision alone cannot establish a current snapshot: the
new native source needs a canonical content digest or dedicated revision for
all three contributors. Environment identity must hash resolved profile
values, including defaults inherited from `BiomeEnvironmentProfile.gd`, not
merely raw `.tres` bytes; raw file hashes are separate provenance.
For Citadel land use, `request_bounds` is the pre-RNG readiness gate;
`source_state` is a non-enqueuing lookup. Both `prepared` (evicted
reconstructible scene source) and `ready` supply the same durable
`reservationCells` and source signature, while `absent` has no reservation.
The snapshot must not mistake cache residency for physical-source identity.
Natural-exclusion rectangles use inclusive max cells; terrain-footprint
records use inclusive `minCell`/`maxCell` XZ bounds. The production query
tests those sources in that order with zero margins before checking Citadel
reservation intersection. Tree recipe exclusion later uses separate margins
and must not be folded into this pre-roll gate.
The immutable structure snapshot should carry the world/generation identity,
inclusive natural-exclusion and terrain-footprint rectangles with stable
record IDs, and per-intersecting-region Citadel decision status, source key,
source signature, reservation rectangle, and admission generation. A canonical
content digest over these sorted semantic records is required even if an
epoch counter is added. The native query can return provenance for the first
blocking source, but must reproduce the Boolean admission and not depend on
Dictionary insertion order or retained scene-source cache entries.
Capture belongs to `StructureSystem` on the main thread after the exact
28×28 `request_bounds` reports `ready`; pending/failed admission must leave
the prop PCG untouched. A non-enqueuing `source_state` result of
`absent:source_not_requested` is not by itself a decided absent site:
`request_bounds` may have skipped a region because its candidate declared
influence does not intersect the chunk. Snapshot identities should separate
the world/generation epoch from the local content digest so unrelated-region
work does not invalidate this chunk, while reset always does. Natural and
terrain rectangles are inclusive; Citadel `Rect2i` reservation intersection
is half-open. Cache eviction may change `ready` to `prepared` without
changing physical identity. A direct Godot oracle must cover those cases,
negative/seam edges, record replacement/reset, insertion-order permutation,
and all 28 live Boolean decisions before native publication can trust it.

The shadow native snapshot now requires an explicit ready, 28-aligned bounds
admission receipt and returns an incomplete decision for any query outside
those bounds or any uncaptured Citadel region. The capture adapter must still
obtain this receipt from the actual `request_bounds` owner; a caller-created
ready value is not production evidence.

The direct headless catalog oracle at
`artifacts/native-world-backend/n4-biome-environment-snapshot-oracle-04/report.json`
passed all 13 resolved profiles, exact float32/float64 sink bytes, and the
explicit default fallback. Its semantic catalog digest is
`130aae151cc57c5e00e227dbc0ed11187b74a7a7dae3df734db169654b61e2e4`;
the 15 source-file hashes remain separate provenance. This is the Godot
reference snapshot for a future native catalog, not native parity or gameplay
acceptance.

The current Godot `removed_props` check occurs before structure/surface and
the prop roll. Consequently a removed root shifts every later shared-RNG
decision in that chunk. Filtering completed native definitions instead would
change existing save replay, despite being a cleaner long-term contract. This
is an explicit migration choice requiring save-ID/reload differential evidence,
not a parity claim or a test-only normalization. Ore child removals have a
similar draw-order consequence inside their selected cluster recipe.

**Migration decision:** preserve the existing save replay during cutover. The
direct Godot `N4SurfacePropRngOracle.gd` v2 contract fixes the first attempt
as an ordinary rock and compares an intact root with a removed root. Both
begin at `atlas-1492:16,17:0`; the next ID is respectively
`atlas-1492:22,22:1` and `atlas-1492:14,9:1`. Its focused headless run passed
on 2026-09-22; the report is
`artifacts/native-world-backend/n4-removed-root-rng-oracle-01/report.json`.
This is a synthetic RNG/source-order contract, not live-save
acceptance. The current unfiltered native attempt stream and baseline replay
cannot serve as the production 28-attempt authority because they assume a
fixed coordinate stream and post-definition tombstone filtering. A native
producer must drive each coordinate, tombstone gate, source decision, class,
and recipe from one advancing PCG in the live order. Keep the existing stream
types as shadow diagnostics until that producer and a real save/reload
differential prove replacement parity. A future decision to make removals
non-perturbing should be a separately versioned gameplay/save change.

The next physical-definition bridge must consume the source-ordered entries
directly, not reconstruct a fictitious unfiltered baseline. In particular,
`make_rock` draws its visual spec before querying `prop_biome_for_position` at
the transformed and rounded placement position. That visual biome may differ
from the terrain sample used to classify the original attempt. Preserve and
test both source facts before producing rock asset and collider definitions.

The follow-up v3 direct Godot oracle extends the same synthetic first-rock
versus removed-root pair through all 28 attempts, with later eligible attempts
consuming a no-feature prop roll. The report is
`artifacts/native-world-backend/n4-removed-root-rng-oracle-02/report.json`:
the final IDs are `atlas-1492:21,15:27` (intact) and
`atlas-1492:6,5:27` (removed), with different final PCG states. This is a
full-chunk RNG-order target for the native producer, not yet a terrain,
structure, recipe, save/reload, or gameplay acceptance result.

**Float-boundary correction (shadow only):** The initial native classifier
narrowed cumulative profile cutoffs to float32, but live Godot keeps those
cutoffs at float64 and promotes each float32 `randf()` value for its strict
comparison. The boundary is reachable: seed `22929874` produces attempt-zero
roll bits `0ad7a33d`; that roll is below the live `0.08` cutoff but equal to
the narrowed float32 cutoff. The direct Godot v4 oracle confirms the live
rock decision and the contrary narrowed decision. Native policy cutoffs now
remain float64, and shadow source/trace/placement receipts advance to revision
4 and SPT4/SPP4 to reject stale identities. The focused native gate
`n4-snapshot-f64-cutoff-03` passed 364/364 debug and release core tests, both
adapter smokes, and 8,262/8,262 lines, 1,107/1,107 functions, and
4,840/4,840 branches of strict pure-core coverage. Its receipt is
`artifacts/native-world-backend/n4-snapshot-f64-cutoff-03/report.json`.
This is not live-gameplay or production-cutover evidence.

**Ore-child source-order witness:** A direct Godot v5 synthetic oracle now
keeps the first iron-cluster root intact and removes only child one. The
second attempt changes from `atlas-1492:16,10:1` to
`atlas-1492:24,23:1`; the final attempt changes from
`atlas-1492:22,3:27` to `atlas-1492:9,19:27`. The signed final PCG states
are `-1028004439998731049` and `-814739496189227464` respectively. The
report is `artifacts/native-world-backend/n4-ore-child-shift-oracle-01/report.json`.
Child zero has the parent ID, so removing it at the ordinary spawn entry
skips the entire cluster before `make_ore_cluster`; a child-zero-only
cluster-helper case is synthetic, not a reachable live spawn case. This
oracle fixes operation order, not source classification, visual publication,
or live save/reload parity.

**Ordered placement bridge contract:** The physical placement successor to
SPP4 must consume all 28 `NativeSurfacePropSourceOrderedStream` entries
directly. It must not rebuild an unfiltered attempt/baseline pair or resample
terrain after the source decision. Use each entry's captured effective surface
and source digest for anchored outcomes; retain an explicit absent record for
parent tombstones, blocked/no-surface/town outcomes, and no-feature rolls.
Preserve the exact float32 chunk-origin/local/world transform boundary and
bind the receipt to world identity, generation, source revisions, ordinal,
durable ID, and cell. Give the ordered receipt a distinct schema/digest so it
cannot be confused with an intact-shadow SPP4 receipt. Focused tests need
negative-chunk and seam frames, edited support, deterministic digest/revision
changes, stale pin rejection, and no RNG or terrain-query work during bridge
construction. Downstream rock definitions must separately reproduce Godot's
visual-biome query at the transformed rounded position; the classifier's
sampled biome is not automatically that visual biome.

**Tombstone footprint boundary (2026-09-22):** The ordered producer's source
chunk is 28 by 28 cells, with 28 attempt centers at offsets +2 through +26.
A parent tombstone bypasses classification and recipe draws before the next
coordinate pair. An ore-child tombstone can likewise skip draws inside its
cluster recipe. Thus the physical rock or ore-child shape alone is not a
complete invalidation footprint: later attempt positions, durable IDs,
outcomes, and generated features can all change. The source-ordered stream
and ordered placement bridge can replay intact and removed snapshots against
one pinned terrain/environment/exclusion source and compare the full 28-entry
sequence. That comparison is useful shadow evidence, but it does not yet
produce complete render, collision, terrain-source, and navigation runs for
all affected feature families. In particular, ore/forage/wildlife do not yet
have complete typed publication envelopes, and wildlife can move after spawn.
Keep `WorldDeltaStore` production `removedProps` admission fail-closed for
unknown IDs. Do not promote a catalog of rock-only local shapes, or a
changed-ordinal witness, as a complete v2 checkpoint receipt. The next
bounded witness should compare before/after source-order streams (including
restoration) and explicitly mark channel footprints incomplete; full cutover
requires the changed suffix's typed or live-publication occupancy and a
transactional differential receipt.
