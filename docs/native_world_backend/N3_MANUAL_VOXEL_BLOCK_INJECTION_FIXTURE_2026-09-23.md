# N3 manual VoxelTerrain data-block injection fixture

The current `VoxelGeneratorScript._generate_block` API is a worker-threaded,
one-shot `void` callback with a borrowed output buffer. It cannot return
"shaping pending" or retain that buffer for a later retry. Voxel Tools also
supports `VoxelTerrain.automatic_loading_enabled = false` with externally
supplied data blocks through `try_set_block_data`. This makes a native-owned,
retryable source/publication queue a plausible N3 path without fake air or a
second terrain generator. This is an API hypothesis until proven in the game.
The boundary is documented by the upstream
[generator callback](https://voxel-tools.readthedocs.io/en/latest/api/VoxelGeneratorScript/)
and [manual terrain-loading](https://voxel-tools.readthedocs.io/en/latest/multiplayer/)
contracts; the fixture tests the installed Voxel Tools build, not only those
docs.

`tools/run-n3-manual-native-block-injection.mjs` launches a separate headed
fixture with an owned Godot process. The fixture has no script or native
generator installed in `VoxelTerrain`, sets automatic loading off, and
constructs 16-cubed `VoxelBuffer`s from the shadow native encoder's SDF16,
indices and data5 bytes. It inserts 27 neighboring blocks, retains real
viewers requesting visuals and physics, and waits for a mesh event,
`is_area_meshed`, and a physics ray whose collider is the actual
`VoxelTerrain`. A second viewer stands at an unresolved native shaping block;
two explicit native requests return pending without bytes and no data block
appears there. This is a real engine mesh/collider fixture, not a production
Main-scene playtest or collision-backed actor-movement acceptance.

The final focused headed report on the current native build at
`artifacts/native-world-backend/n3-manual-native-block-1790155233721-987a8116/report.json`
passes with one mesh event and a `VoxelTerrain` physics hit. Its screenshot is
`artifacts/native-world-backend/n3-manual-native-block-1790155233721-987a8116/headed-terrain.png`;
the owned-process receipt is
`artifacts/node-tools/process-runs/godot-8yau1h/watchdog.json`
(functional exit 0, cleanup passed, zero processes). Dummy audio was used.
The isolated screenshot shows a small visible terrain patch; it does not
establish normal-world visual quality. The initial fixed ray missed an empty
column; the final bounded footprint scan found the actual collider.

This synchronous diagnostic construction took about 50 seconds to encode and
insert 27 blocks in one physics frame. That is **not** an acceptable
production frame budget. Production needs one owner to capture immutable
source/delta/shaping pins, a retryable bounded queue and off-main pure-core
encoding, then measured main-thread buffer installation and physics
acknowledgement. It must prove pending-to-ready completion, stale
seed/revision rejection, unload/revisit, save-v2 edits and actor-safe
collision replacement before replacing the script generator. The later N5
collision-owner cutover must still remove viewer-generated collision rather
than installing a duplicate.
