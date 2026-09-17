# N0 Scope, Contracts, And Preserved Baseline

Date: 2026-09-17

Migration authority: `CODEX_NATIVE_WORLD_BACKEND_MIGRATION_HANDOFF_2026-09-17.md`

Release authority: `docs/WORLD_STREAMING_MATURITY_MIGRATION_PLAN_2026-09-14.md` section 6

Status: N0 contract freeze; Gate 5 remains open

## 1. Repository state and authorization

The migration is confined to the `voxel-biome-world-godot-citadel-visuals`
worktree on branch `codex/world-streaming-maturity-migration`.

| Fact | Value |
|---|---|
| Runtime parent before the handoff | `d507d01a97dca78ad1c29b4602a4af2c7b8e093d` |
| Handoff documentation commit | `c5b424f31091e92f4e4714012ef966a6a99e8c9b` |
| Inherited Gate-5 preservation commit | `cfcc96f2ebcb6a4c171cd37aca52fff6b65a6d8e` |
| Preservation commit meaning | Exact 98-path inherited working state; explicitly not acceptance |
| Starting dirty inventory | 75 tracked modifications, 23 untracked files, 0 staged files |
| Dependency revision | `godot-cpp` `ba0edfed90512ec64aba51d4295a3e7e30112f86` |
| Godot | `4.6.1.stable.official.14d19694e`, Forward+, single precision |
| Platform | Windows x86-64, MSVC 19.44.35228 / Build Tools 14.44.35228 |

The repository has no registered Git submodule. The `godot-cpp` checkout is an
external/ignored build dependency whose pinned revision must be recorded and
whose cleanliness must be proven by each native build receipt.

The user approved reusing the branch's existing baseline rather than producing
another unchanged baseline. That approval avoids a redundant run; it does not
upgrade any historical diagnostic into acceptance evidence. New native-stage
claims must bind source inventory, dependency identity, compiler flags, binary
hashes, runner inputs, and owned-process cleanup in a new receipt.

No production authority is removed at N0. Voxel Tools, the custom
`TerrainMeshingBackend`, and `BuildingSupportKernel` are existing native
components, but no unified authoritative native world-source/collision backend
from this migration exists yet.

## 2. Preserved evidence and limits

Ignored `artifacts/` files remain local evidence and are not forced into Git.
The table records the reusable anchors whose files are present in this
worktree. Historical envelopes do not all contain a complete source/binary
provenance chain; that gap is part of the baseline.

| Evidence | Identity / input | What it proves | What it does not prove |
|---|---|---|---|
| `artifacts/performance/gate5-32npc-route-reviewed-minimal-1080p-10s-120warmup-06/report.json` | SHA-256 `9976a4ad285a3e2dd5f0c40b9edd2512c95f952b56a81eb646fc893ff4a9b9af`; seed `atlas-1492`; 1920×1080; synthetic 32-NPC diagnostic population | The route atom met the preserved diagnostic bounds: p99 0.781 ms, max 1.427 ms, 48 cheap steps, two validators, clean owned-work drain | It failed whole-frame acceptance: Main p99 27.548 ms and presentation p99/max 47.6/52.885 ms; it is not an ordinary-production population or live Gate-5 acceptance |
| `artifacts/world-streaming-maturity/g5/focused-sprint-viewer-workload-attribution-01/report.json` | SHA-256 `95ef4d894450ba5083b1029a618b02042b8680dab19b048e9752b4102ef85a72`; seed `atlas-21838840`; 60 seconds | 533.75 m ordinary-input travel, zero collision holds, Main p99/max 12.776/22.608 ms | It is not the required five-minute pass; it failed due to a navigation snapshot atom over 2 ms; startup was 103.159 s; Voxel Tools tasks peaked at 708 and ended at 343 |
| `artifacts/npc/reports/route-both.json` | SHA-256 `427bdb9ada8bb1fb0ed69b7c87c9f2361d160154f633d448feec88fa899c8b60`; commit field `d507d01a97dca78ad1c29b4602a4af2c7b8e093d`; seed `atlas-1492`; command family `node tools/npc/run-npc-route-tests.mjs -TimeMode Both` | The preserved report records 190/190 focused route contracts during the inherited run | Contract evidence is not headed movement acceptance and does not contain a digest of the 98-path dirty state later preserved by `cfcc96f`; exact-source equivalence is unproven |
| `artifacts/world-streaming-maturity/g1/baseline-20260914/` | Six preserved reports: compile smoke, startup readiness, terrain-navigation mapping, navigation shutdown, NPC contracts, all-NPC aggregate | Historical G1 baseline and known failure inventory | The aggregate contained five registry failures and predates the N0 checkpoint |
| `artifacts/world-streaming-maturity/g5/world-signature-*` | Existing attempted world-signature runs | The runner reached a structured `startup_loading_not_ready` result in two attempts | The current-source dummy/headless access violation remains unresolved; these runs do not prove determinism |

There is no completed menu-to-exit Gate-5 journey, no accepted loading-duration
comparator, no current native five-minute wilderness/Citadel pair, no 30-minute
three-revisit soak, and no known-plus-two-fresh-seed native parity result.

Known inherited defects remain classified, not waived:

- tutorial perimeter gate/fence destruction can convert the bridge into pickup
  material and break the repair quest;
- the headless world-signature/access-violation path is unresolved;
- the 32-NPC whole-frame target fails despite a passing route atom;
- the focused sprint retains an unbounded Voxel Tools task fan-out and a
  navigation snapshot overrun;
- historical civic-recipe parity failures remain documented in
  `docs/WORLD_STREAMING_MATURITY_MIGRATION_PLAN_2026-09-14.md`.

An unexplained regression in protected route, motor, door, traffic, save, or
publication behavior is a stop-work condition. A known inherited failure may be
carried only while its identity, scope, and evidence limit remain explicit.

## 3. Installed binary and toolchain inventory

| Binary | SHA-256 |
|---|---|
| `terrain_meshing_backend.windows.template_debug.x86_64.dll` | `50e6004d539dff92f30e136f9a6298a32e4f3fda84dd522907015d8ee31e4571` |
| `terrain_meshing_backend.windows.template_release.x86_64.dll` | `fb02febd19cc41ad32f0b9a793ce67689cb0ce290d01152d4979e7abc14959ee` |
| `libvoxel.windows.editor.x86_64.dll` | `b24cc4eb8d22c27ce5babf1cf23190571d4acca9b2d215cf9c9adf00614bfc97` |
| `libvoxel.windows.template_release.x86_64.dll` | `d32cef940272e35ebf889cbafa8d7d773cab703b9a553da10c9fc27596750c89` |
| Godot console launcher | `bd9e27c6994a128aaab45cdda4d372de87b91900618ba2de55c6aa29248d5b56` |
| Godot engine | `1e5efe381f62ee1cea6bc18caac71c0c74bd6e68e6af5c6efb3dbe76628f61c7` |

Voxel Tools is the pinned `v1.6x` binary distribution; archive SHA-256 is
`dfee985a0cff7059a31ada665e88a634fdcc3eab51f83fe5f6dd48939dd5372a`.
The generated `godot-cpp` API is Godot 4.6 single precision; its
`extension_api.json` SHA-256 is
`53d37f85be32b6d10fb2266ca51f6ef0c3a55728acdb7c8301b1458a93c00943`.

These DLL hashes match the historical G0 inventory, but no existing receipt
cryptographically joins the full current source tree to those binaries. The
current SConstruct applies `/O2` to debug and release and applies `/fp:strict`
only to `BuildingSupportKernel`. N1 must separate optimized production,
debug-test, strict-FP, and coverage targets; emit PDBs; and prove the installed
copy came from the complete expected source list.

## 4. Frozen world identity and deterministic numeric contract

The following is the compatibility contract, not permission to modernize the
algorithm during the port.

### 4.1 World identity

1. The input seed is the exact Godot `String` code-point sequence. N0 does not
   add Unicode normalization, case folding, trimming, locale conversion, or an
   implicit UTF-8-byte reinterpretation.
2. The legacy generation hash is FNV-1a-like over each Unicode code point in
   order: initial value `2166136261`, XOR the code point, multiply by
   `16777619`, then mask to unsigned 32 bits after each step. Native tests must
   include ASCII, non-ASCII BMP, supplementary code points, empty strings, and
   embedded punctuation used by stable IDs.
3. Identity is split into three layers. `SourceKey` contains exact seed code
   points, legacy seed hash, world-generator revision, biome-field revision,
   feature-recipe/schema revision map, save/delta schema revisions, and frozen
   world constants. `SnapshotKey` adds bounded source coordinates, ordered
   terrain/feature delta revision vectors, and owner generation. `ArtifactKey`
   contains the `SnapshotKey` digest plus artifact kind, builder revision,
   detail/LOD/channel policy, and seam/halo policy. Builder upgrades never
   change world/source identity.
4. The current constants are compatibility inputs, including `CELL = 1.35`,
   terrain section size 16, `CHUNK_SIZE = 28`, `MIN_HEIGHT = 4.0`,
   `MAX_HEIGHT = 120.0`, `WATER_LEVEL = 11.1`, town region size 280 cells, and
   world bottom cell Y `-64`. A change is a reviewed world-format decision.
5. The current version map is part of `SourceKey`: the unversioned legacy world
   generator is identified by preservation tree `cfcc96f`; biome field 2;
   terrain-volume/delta schema 1; Citadel site field 1; Citadel survey and
   generation policies 1; building terrain profile 1; town runtime manifest 1;
   building interior program 2; building navigation manifest 9; furnishing
   navigation manifest 2; courtyard placement 1; landmark recipe 1;
   procedural tree grammar 2; tree spawn recipe 10; savanna 2, conifer 2, and
   bushy-oak 21. N1 turns this map into typed constants and fixtures; it does
   not infer versions from class availability.
6. Save envelope version remains `2`. N0 does not restore v1 migration and does
   not bump a version merely to bless native drift.

Canonical identity bytes use a versioned binary envelope, not JSON or locale-
formatted text: ASCII magic `VWBK`, unsigned little-endian schema number,
length-prefixed fields in the order above, seed as a count followed by unsigned
32-bit Unicode scalar values, signed integers as two's-complement little-endian,
and floating constants as their declared IEEE-754 bit patterns. Maps are sorted
by UTF-8 key bytes; arrays retain semantic order. SHA-256 of those bytes is the
cache/receipt digest, while generation continues to use the frozen legacy
32-bit seed hash. Duplicate keys, invalid scalar values, non-finite floats, and
unknown schemas are rejected.

### 4.2 Coordinates, density, and seams

- Global cell and tile keys use the full signed 32-bit range
  `[-2147483648, 2147483647]`. Section ownership uses
  mathematical floor division by the positive section size. Local coordinates
  use Euclidean modulo in `[0, size)`. Native `/` and `%` truncation are never
  used directly for negative cells.
- Public Godot coordinates are `Vector3i`; native conversion checks range and
  rejects overflow rather than wrapping. Products used to form origins,
  neighbourhoods, and linear indices use checked 64-bit intermediates and
  reject a result that cannot return to the declared signed-32 domain.
- Terrain generation samples the lattice origin `Vector3(cell) * CELL`, exactly
  as `VoxelTerrainGenerator.gd` does; there is no `+0.5` cell-center offset.
  Cast, multiplication, interpolation, and quantization order match the frozen
  GDScript oracle. Halo ownership is half-open: an artifact owns its core
  interval and reads the declared positive/negative halo without claiming it.
  Seam-neighbour invalidation is explicit in each artifact contract.
- World-generation density is solid when `density >= 0`; negative means air.
  Voxel Tools SDF is the negated normalized value, currently
  `-density / CELL`, so negative Voxel SDF means solid. Zero is part of the
  solid-side world classification. This sign boundary must be tested directly.
- Material, fluid, light, biome, and solidity are typed source channels.
  Render indices, SDF quantization, collision triangles, and navigation support
  are derived outputs and may not invent different occupancy.
- Empty output is a valid sealed artifact and requires the same acknowledgement
  lifecycle as non-empty output.

### 4.3 Floating-point compatibility

- Parity is defined against frozen golden fixtures plus an independent
  reference oracle; a golden generated only by the ported implementation is
  insufficient.
- The deterministic core is built without fast-math, contraction, or implicit
  FMA changes. MSVC strict floating-point behavior is required for covered
  deterministic translation units. Compiler identity and effective flags are
  receipt fields.
- Godot engine boundaries use the generated single-precision ABI. The pure core
  may use an explicitly declared wider intermediate only where the frozen
  oracle already does; every float/double/real_t conversion point is tested.
- Noise type, seed arithmetic, frequency, octave count, gain, lacunarity,
  interpolation order, rounding, clamping, SDF encoding, and material
  threshold order are contract data. N1 fixtures freeze them before N3 ports
  production generation.
- Exact equality is required for integer/stable-ID/material/biome/solid/fluid
  facts. Floating tolerance is field-specific and declared in the fixture;
  tolerance cannot cross density zero, material thresholds, cell ownership, or
  stable-ID choices.

N1's reproducibility guarantee is initially Windows x86-64, Godot 4.6.1
single-precision ABI, and MSVC 19.44 with recorded strict-FP flags. Worker
count/order may not affect results. Linux, macOS, other compilers, SIMD modes,
and later engine ABIs require their own differential fixtures before they can
become compatibility or release targets. They cannot claim equivalence for an
existing sparse-delta save-v2 world merely by regenerating its baseline.

## 5. Snapshot, delta, and save-v2 contract

Native work consumes immutable, revision-pinned snapshots. A snapshot contains
only source facts and typed deltas; it never retains live Nodes, Objects,
Resources, callables, or mutable script dictionaries. Every request and result
carries source binding, owner generation, transaction ID, cancellation epoch,
input revision vector, artifact revision, and deterministic signature.

### 5.1 Delta semantics

- `absent` means no override and therefore exposes deterministic generation.
  It is distinct from an explicit air cell (`solid=false`, negative density)
  and from a generated-feature tombstone.
- Terrain cell overrides, scene/player blocks, generated-feature tombstones,
  dynamic door state, and gameplay-system state remain separate typed
  namespaces. One must not resurrect or double-install another.
- Generated features use their source-derived semantic ID as the durable key.
  A tombstone removes that exact source feature. A patch record carries the
  same semantic ID, expected source/recipe revision, patch schema, and sorted
  typed field operations; it cannot rename the feature or target a different
  base revision. Duplicate identical patches are idempotent. Conflicting patch,
  tombstone, or revision records fail closed rather than applying by arrival
  order. Durable feature state that is not deletion is represented as a patch,
  never as a copied replacement feature.
- Player-created instances use a disjoint
  `player/<SourceKey digest>/<unsigned-64 counter>` namespace. Save v2 gains
  additive optional `playerInstanceCounter` and per-instance `instanceId`
  fields; the counter is monotonic, persisted, overflow-checked, and never
  reused after removal. Existing v2 `blocks` without IDs import in canonical
  `(cell.z, cell.y, cell.x, type, original-index)` order, receive consecutive
  IDs after all valid explicit IDs, and write those IDs on the next save.
  Duplicate IDs with identical records are idempotent; different content under
  one ID, a counter below an observed ID, or collision with the generated-ID
  namespace rejects the transaction.
- Section order is deterministic `z, y, x`; cell order within a section is the
  same. Replay of the same transaction is idempotent. Duplicate transaction IDs
  with different content, conflicting revisions, malformed arrays, overflow,
  unsupported schemas, and oversized inputs fail closed.
- A transaction is applied entirely to the pinned source revision or rejected;
  partial success is not published. Compaction preserves the same ordered final
  cell state and tombstones. Cancellation cannot mutate accepted state.
- Terrain edit invalidation includes the owner tile and required seam
  neighbours. Safe collider swaps recheck actors at the physics boundary and
  retain the old accepted artifact until the replacement is acknowledged.

### 5.2 Durable v2 inventory

The current envelope records seed/time/player transform; weather and tutorial;
inventory and crafting; legacy-within-v2 `terrain` column edits;
`terrainVolume` schema-1 section deltas and revisions; subsurface state;
`removedProps` generated-feature tombstones; survival, progression, equipment,
objectives, and contracts; story; NPC job facts; exploration; death/respawn,
beacon raid, and sanctuary facts; and player `blocks` including door portal and
group IDs, open/locked/jammed/destroyed flags, chest slots, and furnace state.
Missing optional fields retain their existing v2 defaults.

Generated structures, town/home assignments, static portals, and ordinary
generated ecology are reconstructed from the seed and their stable source
identities rather than serialized as a second generated world. Their durable
exceptions live in the typed facts above: terrain edits, feature tombstones,
player blocks/door state, tutorial/story/progression facts, and NPC job facts.
N3–N7 parity tests must prove this reconstruction and must not add an implicit
second generated-world snapshot to save v2.

Godot continues to own the save envelope, file/slot selection, temp-and-replace
file coordination, UI/progress, scene mutation, rewards/drops, and restore
orchestration. `SaveSystem._write_text_atomic` is not yet proven crash-atomic:
its fallback removes the old target before renaming the temporary file. N7 must
verify or repair that replacement protocol before claiming crash atomicity.
The native backend may validate/import/export its typed terrain/feature delta
payload but does not become a second save system.

## 6. Concurrency, acknowledgement, and lifecycle contract

1. Capture immutable inputs on the owning thread, then release all engine
   references before worker execution.
2. Worker output is sealed before enqueue. Publication occurs only when world
   identity, owner generation, revision vector, transaction ID, and
   cancellation epoch still match.
3. Generation/build completion is not publication completion. Render, physics,
   navigation, and interaction consumers provide separate acknowledgements.
4. Superseded and cancelled results retire without callbacks into released
   state. Shutdown stops intake, cancels queued work, joins workers, drains or
   rejects results, removes accepted engine artifacts at a safe boundary, and
   proves zero owned descendants/threads.
5. Queue caps cover requests, bytes, work units, completed-but-uninstalled
   artifacts, engine registrations, and retirements. A broad viewer or one
   oversized artifact may not bypass the hard cap.
6. Static snapshots never bake dynamic actors or door-open state. Doors retain
   their declared static portal identity while runtime state remains with the
   existing door/traffic authorities.
7. All gameplay publication shares one 6,000 µs aggregate frame allowance.
   Citadel publication receives at most 4,000 µs and never more than the shared
   remainder. Native capture, marshalling, installation, acknowledgement, and
   retirement are charged to the same frame token/deadline; subordinate
   services never mint a fresh budget. Receipts record source-to-visible and
   source-to-usable latency, consumed work, maximum unsplittable atom, overrun
   owner, retained age/backlog, and producer backpressure.

## 7. Native boundary and protected gameplay authority

N1 extends the existing `native/terrain_meshing` SCons/godot-cpp stack rather
than introducing a parallel dependency stack:

```text
native/world_backend/core/    Godot-free value types and deterministic kernels
native/world_backend/tests/   standalone executable and independent fixtures
native/world_backend/godot/   thin Variant/ClassDB/engine-publication adapters
```

The pure core has no Godot headers, `Object`, `Variant`, scene mutation, global
RNG, file I/O, or wall-clock policy. Every new first-party native component gets
standalone tests. Coverage targets line, function, and branch coverage at 100%;
any justified unreachable/tool-generated exclusion is enumerated by source line
and independently reviewed. The runner fails when an expected source is absent
from the denominator.

The native navigation scope at N6 is limited to source-derived topology,
support/clearance artifacts, deterministic tile/seam/vertical mapping, declared
structure connectivity, spatial indexes, and agreed CPU route/proof-preparation
kernels. The following stay authoritative in the existing gameplay stack:

- route-state semantics and exact request ordering;
- leases, cancellation, and repair policy;
- final live collision and dynamic-occupancy proof;
- CharacterBody movement motors;
- door and portal runtime authority;
- traffic, yielding, and dynamic actor physics;
- NavigationServer synchronization and acknowledgement policy.

There is no Recast/native-chunk-raster restart and no second production
topology. The prior Citadel study rejected that wholesale replacement.

## 8. Voxel Tools boundary

Voxel Tools remains a render consumer during migration. Its current production
path also generates collision and broad viewers can enqueue hundreds of opaque
jobs. The installed public surface observed in this repository has no proven
API for injecting a project collision artifact into a specific 16-cell block,
no exact install/physics-sync receipt, and no demonstrated hard per-viewer job
cap. N1 therefore performs a ClassDB reflection probe before claiming an API
blocker; no plugin or engine fork is authorized by current evidence.

N2 uses one bounded fixture: a native source snapshot, native-derived
project-owned collision shape, one project-owned `StaticBody3D` authority, and
an explicit physics-frame acknowledgement. Voxel Tools collision generation
and viewer collision demand are disabled only inside that fixture. N5 disables
them in production only after parity and live movement prove the replacement;
duplicate colliders are never accepted.

## 9. Loading policy

Loading duration remains fail-closed. The matrix status
`gate5_blocked_duration_policy_unresolved` and `gate5LoadingAccepted: null` are
intentional until an approved comparator/envelope exists. The provisional
90-second cold, 45-second warm, and 1.10 ratio values are not acceptance
thresholds. A known 127.627-second run is not acceptance evidence.

## 10. Stage and deletion gates

- N1: pure core, deterministic primitives, standalone tests, coverage and
  source/build/install receipts. No production cutover.
- N2: narrow vertical slice with exactly one collision authority in its fixture.
- N3: native terrain/biome/delta source becomes production authority; delete
  the per-voxel GDScript generator and copied edit-composition path after parity.
- N4: native feature/structure/Citadel/ecology source contracts; preserve
  scene/visual publication adapters and dynamic gameplay state.
- N5: collision-first streaming becomes production authority; disable Voxel
  Tools collision demand and remove superseded callback-style meshing/fallbacks.
- N6: bounded native navigation/query CPU behind protected route contracts.
- N7: persistence, interactions, lifecycle, and remaining consumer cutovers;
  delete deprecated production paths after consumer inventories are empty.
- N8: performance convergence, binary/source freeze, and bounded queues.
- N9: the complete Gate-5 matrix on the final native build.

Each deletion requires: passing standalone parity/coverage, Godot adapter and
lifecycle tests, real live evidence appropriate to the player-visible boundary,
consumer search showing no production callers, independent review, and a
checkpoint commit. Rollback is by the preceding commit, not a permanent runtime
fallback or `ClassDB`-selected dual authority.

## 11. N0 focused verification

The documentation and preserved checkpoint were checked without creating a new
unchanged headed baseline:

| Command | Result | Evidence limit |
|---|---|---|
| `node --test tools/tests/owned-process-watchdog.test.mjs tools/tests/citadel-candidate-runners.test.mjs tools/tests/runtime-performance-observation.test.mjs tools/tests/world-streaming-loading-matrix.test.mjs` | 63 tests passed, 0 failed; includes real Windows owned-process fixtures and fail-closed loading/provenance checks | Unit/synthetic runner validation; no Godot gameplay |
| `node tools/run-project-compile-smoke.mjs --report-path artifacts/native-world-backend/n0-20260917/compile-smoke.json` | Passed; report SHA-256 `6226e51966bf56caf5e96e5ed8661ff2c7505f2879b62da79973b503baf08aee`; main menu and main scene loaded; owned process exited cleanly | Parse/load smoke only; no gameplay or native-backend claim |
| `node tools/run-world-streaming-consumer-contract.mjs --output-directory artifacts/citadel-runtime-integration/world-streaming-consumer-n0-20260917-01` | Passed; report SHA-256 `f536318a344c6bda754ef12b3435fe15133c80168f56208fae45babf55e6a0e8` | Synthetic retained-consumer contract; explicitly no frame scheduling, source generation, scene collision, NavigationServer, route, movement, performance, or live gameplay proof |

The first attempted consumer-contract invocation used a directory outside the
runner's required `artifacts/citadel-runtime-integration/world-streaming-consumer-*`
policy. It failed before process launch or evidence creation. The passing command
above used a fresh compliant path; no preserved artifact was overwritten.

`git diff --check` and no-index whitespace checks over both new untracked
documents pass after review.

## 12. N0 exit decision

N0 is complete when this contract and the companion migration ledger are
reviewed, the older backlog language is marked historical, and focused compile/
runner validation is green. Completion of N0 authorizes N1 only. It does not
claim a native backend, Gate-5 acceptance, merge readiness, or permission to
modify the protected route/motor/door/traffic implementation outside the
handoff's stated boundaries.
