# N2 First End-To-End Vertical Slice Contract

Date: 2026-09-17

Migration authority: `CODEX_NATIVE_WORLD_BACKEND_MIGRATION_HANDOFF_2026-09-17.md`

Status: implemented and verified; fixture-only activation, no production cutover

Completion evidence is recorded in
`N2_FIRST_END_TO_END_VERTICAL_SLICE_2026-09-17.md`. This file remains the
frozen behavioral contract and records the source-translation correction found
by its full 33,915-sample headed oracle.

## 1. Stage boundary

N2 ports one bounded, real terrain-source slice into the Godot-free C++ core.
One immutable resolved snapshot feeds both collision geometry and Voxel Tools
render inputs. The native path is first compared as shadow data, then activated
only in a dedicated fixture with exactly one collision authority.

N2 does not cut over the production world, route authority, navigation,
tutorial choreography, saves, or the full generator. Production
`VoxelTerrainGenerator.gd`, production Voxel Tools collision, and the existing
script terrain-volume authority remain until their N3/N5 deletion gates.

## 2. Corrected source translation

The production Voxel Tools source samples lattice origins:

```text
position = Vector3(cell) * 1.35
solid iff density >= 0
Voxel Tools SDF = -density / 1.35
```

That is the N2 source contract. `WorldGenerationSystem.sample_cell`,
`generate_cell_state`, and the current section-payload path sample
`(cell + 0.5) * CELL`; they are gameplay/volume-center queries and are not a
valid N2 source oracle. The current C++ section mesher pairs those center
samples with lattice-origin vertex positions. N2 treats that as a discovered
translation mismatch, not as behavior to preserve. It will extract only the
marching-tetrahedra topology/math from that implementation and feed it the new
lattice-origin snapshot.

The independent GDScript oracle must reproduce
`VoxelTerrainGenerator._generate_block` and
`VoxelTerrainRuntime.generated_state_at_grid_cell` semantics directly:

1. use lattice-origin world coordinates;
2. resolve a typed edit first, if present;
3. otherwise compute reference/deformed surface and density;
4. assign `air` when density is negative, otherwise use the current generated
   solid-material rule; and
5. encode SDF as a 16-bit VoxelBuffer channel and both material channels as the
   same 8-bit material ID.

The bounded N2 lattice generator does not invent generated fluid state: the
current Voxel Tools generator emits density and material only, so generated
snapshot fluid is `none`. Typed deltas still carry and validate an explicit
fluid field. Full generated-fluid/world-volume authority remains an N3 concern;
calling `underground_fluid_for_cell` here would be another source translation.

Parity is ordered typed data, not only a digest, image, or mesh comparison.
Every mismatched cell reports its coordinate and each mismatched field.

## 3. Frozen dependency and precision contract

Do not rewrite the noise algorithm. The vendor baseline is Godot 4.6.1's
patched `thirdparty/misc/FastNoiseLite.h` from engine commit
`14d19694e0c88a3f9e82d899a0400f27a24c176e`, behind one private
first-party wrapper translation unit. Its original header SHA-256 was
`38b24b9b04aa5e9f1e63336d4acbbbb73b11f15b697bb08a25f5ec0c6c274901`.
The local source-only modulo-2^32 arithmetic repair for the production
OpenSimplex2/FBm path retains that provenance and pins the maintained header
at SHA-256 `6e96dcf7b2f7e968e1b47337b2f54a5e7ecf70a32cdab55d6158510629ab248c`.
Godot pins upstream FastNoiseLite 1.1.0 commit
`f7af54b56518aa659e1cf9fb103c0b6e36a833d9`; its license is MIT/Expat.

The wrapper maps Godot `TYPE_SIMPLEX` to `NoiseType_OpenSimplex2` and explicitly
sets `FractalType_FBm`, weighted strength zero, no domain warp, and the default
coordinate transform. Raw FastNoiseLite defaults to no fractal while Godot's
wrapper defaults to FBM, so relying on the raw constructor would be a silent
mistranslation. It creates these five immutable configurations:

| Name | Salt | Frequency | Octaves | Gain | Lacunarity |
|---|---:|---:|---:|---:|---:|
| height | 17 | 0.0058 | 4 | 0.5 | 2.0 |
| ridge | 43 | 0.014 | 3 | 0.5 | 2.0 |
| flat | 71 | 0.0024 | 3 | 0.5 | 2.0 |
| moisture | 107 | 0.006 | 3 | 0.5 | 2.0 |
| temperature | 131 | 0.005 | 3 | 0.5 | 2.0 |

Each noise seed is
`(legacy_seed_hash(seed_text) + salt * 7919) & 0x7fffffff`. Godot is a
single-precision build: coordinates are explicitly cast to `float`, the
vendored sampler is invoked as `GetNoise<float>`, and its `float` result is
then promoted to `double` for the downstream GDScript-equivalent arithmetic.
The first-party core stays `/fp:strict`, with no fast math or contraction.
Debug and release differential fixtures must cover exact returned float bits
for all five configurations, negative and large coordinates, 2D/3D calls, and
density-threshold cases. Third-party header lines are excluded from the
first-party coverage denominator but included in all source/build provenance.
For `atlas-1492`, the legacy hash is `1769472797`; the five seeds in table order
are `1769607420`, `1769813314`, `1770035046`, `1770320130`, and `1770510186`.

## 4. Frozen fixture region and anchors

World seed: `atlas-1492`.

The region is two adjacent 16-cell XZ tiles with one shared immutable source
snapshot:

| Item | Value |
|---|---|
| Tile A | key `(-3,-1)`, core X `[-48,-32)`, Z `[-16,0)` |
| Tile B | key `(-2,-1)`, core X `[-32,-16)`, Z `[-16,0)` |
| Core Y | `[-16,32)` |
| Combined core samples | `32 * 48 * 16 = 24,576` |
| Snapshot halo | one gradient sample beyond every inclusive cube corner |
| Combined sample region | X `[-49,-14)`, Y `[-17,34)`, Z `[-17,2)` |
| Combined stored samples | `35 * 51 * 19 = 33,915` |
| Tile seam | X = `-32` |

Each tile owns half-open cube origins. Tile A samples X `[-49,-30)` and tile B
samples X `[-33,-14)`; both may read the seam but only tile A owns cubes ending
at it and only tile B owns cubes beginning at it. A changed seam sample
invalidates both artifacts. Missing required samples are an error, never
implicit air. N2 accepts only LOD 0/step 1 and rejects overflow while expanding
the sample region.

The slice uses the ordinary deterministic context with no generated site
profiles or pinned town override. Auto-town records can exist in neighbouring
280-cell regions, but their centers/radii do not overlap this slice. N2 does
not port town/site shaping, which remains N3/N4.

Frozen lattice-origin anchors from the current generator are:

- negative-coordinate surface pair: cell columns `(-20,13,-2)` and
  `(-20,13,-1)` both report reference surface Y `17.901000000000003`.
  The pre-implementation value `18.819000000000003` for the second column was
  a direct-by-cell mistranslation: the production generator first stores
  `Vector3(cell) * 1.35` in `real_t`, then the public surface query maps that
  rounded world position back through `floor(position / cell_size)`. The
  headed 33,915-sample oracle exposed and supersedes that assertion;
- seam-crossing cave air: `(-33,-2,-5)` has density
  `-0.6017665929014142`, and `(-32,-2,-5)` has density
  `-0.35286612593816424`; both are non-solid `air` in the swamp surface
  biome; and
- seam edit cells: `(-33,12,-5)`, `(-32,12,-5)`, `(-33,12,-4)`, and
  `(-32,12,-4)` are initially solid `mud` with density
  `0.3260338576977162`.

The four edit cells become explicit air with `density = -1.35`,
`solid = false`, `material = air`, `biome = underground_air`, and no fluid.
They are serialized as typed deltas, not inferred from absence. Reload builds a
new snapshot from seed plus serialized deltas and compares ordered typed output
and artifacts; it may not clone the already-resolved snapshot.

The declared feature blocker is an immutable axis-aligned box with stable ID
`n2:blocker:tile-b:-24,-10`, center
`(-32.4,16.497000000000003,-13.5)`, size `(1.35,2.7,1.35)`, semantic class
`fixture_obstacle`, and `physical_intent = blocker`. Its bottom is the frozen
reference surface Y `15.147000000000002` at column `(-24,-10)`.
It is compiled into the same collision artifact/body as terrain and must have
both positive and negative query probes. N2 must not call
`BuildingPartPublisher` or create a second body for it.

## 5. Immutable snapshot and artifacts

The snapshot owns row-major cells ordered X fastest, then Z, then Y, with
explicit bounds and halo. Each cell contains coordinate, double density,
solid, material ID/name, surface biome ID/name, resolved biome ID/name, fluid,
and source provenance (`generated` or a typed delta ID/revision). Canonical
serialization, digest, source revision, owner generation, and cancellation
token are mandatory.

Two artifact keys derive from the same snapshot digest:

- collision artifact: marching-tetrahedra triangle soup partitioned by the two
  tile cores plus the declared blocker; and
- render artifact: SDF 16-bit, INDICES 8-bit, and DATA5 8-bit arrays suitable
  for VoxelBuffer hydration, with both material channels identical.

Collision compilation cannot depend on render completion or an ArrayMesh.
Voxel Tools remains only a rendering/meshing consumer in this fixture.
Fixture-local Voxel Tools collision generation and collision viewer demand are
false. Production settings are unchanged.

## 6. Publication, acknowledgement, and ownership

The active fixture contains exactly one project-owned `StaticBody3D` on the
terrain collision layer. That body may own two terrain concave shapes plus the
feature-blocker box. There is no VoxelTerrain collider, fallback collider, or
duplicate old/new body in the active fixture.

Replacement is transactional:

1. prepare source, collision, and render artifacts under a request identity;
2. reject a stale/cancelled result before installation;
3. retain the prior body shapes while installing replacement shapes;
4. await at least one physics frame and record the acknowledged physics frame;
5. reject a result that became stale before acknowledgement; and
6. retire the prior shapes only after the current replacement is acknowledged.

Acknowledgement is not merely a frame counter. The fixture must record the
installed snapshot/artifact provenance and prove it through direct-space
queries that return the sole body/shape provenance. Required live checks are
rays above solid and air, cave clearance/solid walls, seam probes before and
after the edit, blocker hit/miss probes, a capsule sweep, and ordinary
`CharacterBody3D.move_and_slide` traversal over the slope and against the
blocker. The fixture actor is generic; N2 makes no player/NPC gameplay claim.

## 7. Bounded work contract

The initial fixed caps are part of N2 behavior, not post-result tuning:

| Resource | Hard cap |
|---|---:|
| admitted requests | 4 |
| in-flight source/collision builds | 1 |
| prepared results awaiting install | 1 |
| prepared native payload bytes | 4 MiB |
| installed body count | 1 |
| installed shapes | 3 |
| collision triangles | 200,000 |
| retired shape sets awaiting release | 4 |
| end-to-end fixture watchdog | 10 seconds |
| post-install acknowledgement | 3 physics frames |

The receipt records source, delta resolution, collision compilation, render
packing, main-thread hydration, install, acknowledgement, and total wall time
separately. A watchdog is a failure bound, not a performance success claim.
N2 reports the measured distributions and does not claim Gate-5 cadence.

## 8. Required N2 evidence

N2 exits only when all of the following pass in debug and release where
applicable:

- standalone source/noise/delta/snapshot/mesher/cancellation tests with the
  first-party line/function/branch denominator reported and targeted at 100%;
- ordered typed parity against the independent current GDScript lattice
  oracle for all 33,915 samples, including material and explicit-air fields;
- deterministic approach/order and cancellation permutations, stale-before-
  install and stale-before-ack rejection, and reload from serialized deltas;
- seam continuity and both tile artifacts changing after the cross-seam edit;
- collision artifact completion before render hydration;
- real GDExtension load/invoke/unload and VoxelBuffer/Voxel Tools render
  consumption;
- the headed one-authority physics fixture and visual inspection, with report,
  trace/screenshots, exact commands, source/binary/input hashes, and natural
  owned-process drain;
- a consumer/deletion audit showing no production cutover or duplicate fixture
  authority;
- independent correctness/lifetime/deletion review with findings resolved or
  explicitly blocking; and
- a focused N2 commit and clean worktree.

## 9. Inherited baseline exceptions

The user approved the branch's existing baseline as the N2 inheritance point.
The current broad NPC report is not reclassified as a pass. Its existing
exceptions are carried transparently and revisited only when the migration
reaches their owning systems:

- Mira's go-home assertion observes a valid route but violates the existing
  five-second visible-departure contract because route work waits on budget.
  N2 must not change routing to mask it. N6, which migrates bounded route/query
  CPU behind the protected route contract, must root-cause and repair the
  servicing latency and rerun the real headed go-home coverage.
- The final rescue targeting assertion correctly reads live targets/counters,
  but the current scenario places Sera's accepted normalized route endpoint
  farther from the hostiles than the player, so all select the player while the
  acceptance still requires NPC aggro. This is a scenario/target-policy
  contract mismatch, not an N2 terrain-source assertion. Revisit it when N7/N8
  reaches that consumer/flow, fix its actual owner (native or script), and
  rerun the real rescue flow.
- Four child-report evidence-integrity assertions, the absent generated latest
  world-signature input, and the known 300-second town-job wrapper timeout also
  remain visible in the baseline report. They are not N2 passes or reasons to
  weaken N2 evidence.

Any N2 production-visible regression remains a blocker despite these explicit
exceptions. Original Gate 5 remains open.
