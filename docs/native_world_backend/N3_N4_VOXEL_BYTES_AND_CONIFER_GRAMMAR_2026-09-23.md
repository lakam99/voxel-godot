# N3/N4 native source preparation: voxel bytes and conifer grammar

This checkpoint adds two pure-core inputs to a future production cutover. It
does **not** change the live terrain generator, Voxel Tools worker, tree spawn
pipeline, collision, navigation or save authority.

## N3 effective voxel block

`NativeEffectiveVoxelBlock` turns one immutable effective-terrain pin into
ZXY-ordered SDF16, indices8 and data5 channel bytes for a VoxelBuffer data
block. The encoder preserves negative lattice coordinates, LOD scaling,
durable edits, current material IDs (including the script generator's lava-to-
stone fallback), source pin identity and terrain/shaping revisions. It rejects
invalid dimensions, coordinate overflow and blocks crossing its primary
280-cell shaping page before returning any bytes. The maximum side is 32 and
LOD is at most 24. It does not publish a buffer or reject a pin made stale
after encoding.

Independent installed Godot 4.6.1/Voxel Tools oracles in
`native/world_backend/tests/native_effective_voxel_byte_oracle.gd` and
`native_effective_voxel_threshold_oracle.gd` verify the byte layout and a
quantization boundary. At density `-10.567796868800928`, CELL `1.35`,
rounding density to float before division produced raw SDF16 `512`; Godot
produces `513` (`[1, 2]` bytes). The native implementation now performs
GDScript's real-number division before the channel float conversion. This
was a migration mistranslation, not a new world-rule change.

The pinned Voxel Tools v1.6x boundary offers
`VoxelBuffer.set_channel_from_byte_array`, so a later thin generator can copy
three complete channels without per-voxel Godot calls or a Voxel Tools C++ ABI
dependency. A shadow-only `NativeEffectiveTerrainPage.encode_voxel_block`
adapter method now transports the three `PackedByteArray` channels, source
identity and revision fields from its immutable single-page pin. Its focused
Godot contract (`artifacts/native-world-backend/n3-voxel-adapter-focused-report.json`)
passes exact edited bytes, malformed/cross-page rejection and old-pin
immutability after an edit. A later focused direct-service differential at
`artifacts/native-world-backend/n3-voxel-generated-byte-differential-03.json`
compares four `VoxelTerrainGenerator._generate_block` buffers on seed
`atlas-1492` against the native adapter's complete channels: surface band,
below-ground, LOD 1 and high air all match byte-for-byte. This invokes the
real script generator directly, but not a live streaming worker or scene.

Before production cutover, admission must cover real cross-page blocks from
one coherent delta and shaping snapshot, compare owner generation plus
source/delta/shaping identity before
publication, retain retryable stale work, and atomically switch the gameplay
terrain query facade and generator to the same native source. Fresh-seed,
edited and crossing-page differentials, New Game/Continue, headed digging,
collision/navigation and save/reload proof remain open. This encoder's
`cell_size_meters` must be admitted equal to the live `CELL=1.35` contract.

## N4 raw conifer grammar

`NativeConiferRecipeBuilder` ports the active mathematical conifer raw grammar
with stable keyed values, branch/foliage caps and its native signature. Four
independent Godot raw-recipe fixtures match branch counts, foliage counts and
signatures. A focused Godot check caught Godot's negative-half-tie `roundi`
rule; native now rounds halves away from zero. Cap branches are exercised by
unit-only lower budgets through the same implementation; the production
builder keeps the unchanged 1120/1480 limits. This synthetic cap exercise is
unit coverage, not gameplay acceptance.

The raw grammar is not the live tree. `TreeSpawnService` still performs
request normalization, graph/foliage reduction, coordinate/radius adaptation,
render LOD selection and runtime signature generation. The next native tree
slice must match those transforms with direct-service oracles across age,
density and LOD. Trunk collision comes from the runtime request, not rendered
branch/leaf bounds; visual and physical publication require their own live
proof. No tree GDScript recipe or collision authority is deleted here.

## Verification and deletion audit

- `node tools/run-native-world-backend-tests.mjs --run-name n4-conifer-n3-voxel-01`
  blocked only on 21 previously unexercised new-source branches; 460/460
  debug/release tests and adapter smokes passed. The exact coverage defects
  were corrected, not waived.
- `node tools/run-native-world-backend-tests.mjs --run-name n4-conifer-n3-voxel-02`:
  `artifacts/native-world-backend/n4-conifer-n3-voxel-02/report.json` passed
  463/463 debug and release tests, editor/release adapter smokes, and strict
  pure-core coverage of 10,467/10,467 lines, 1,422/1,422 functions and
  6,156/6,156 branches.
- The two focused Godot oracle scripts run with the installed 4.6.1 console
  binary and produce `[0,0,65,0,191,255,65,0,1,128,255,127,191,255,0,0]`
  for the 2³ SDF channel and `[1,2]` at the threshold, respectively. These
  are channel-byte oracles, not headed gameplay tests.
- `node tools/build-native-terrain-meshing.mjs --target template_debug --api-version 4.6`
  built the shadow adapter; the focused installed-Godot
  `native_effective_voxel_adapter_contract.gd` passed with no failures.
  This is direct-service marshalling and pin-lifetime evidence, not live
  generator consumption or adapter line/branch coverage.
- The focused installed-Godot `native_effective_voxel_adapter_contract.gd`
  rerun records four generated-block byte matches in
  `artifacts/native-world-backend/n3-voxel-generated-byte-differential-03.json`.
  It does not exercise a Voxel Tools worker callback, a page seam or collision.
- Independent read-only reviews found the rounding and conversion-order
  issues and identified page-seam/freshness/live-recipe boundaries. No live
  caller changed, so no production authority or script sampler is deleted.

N3 and N4 checkpoints remain incomplete; original Gate 5 remains open.
