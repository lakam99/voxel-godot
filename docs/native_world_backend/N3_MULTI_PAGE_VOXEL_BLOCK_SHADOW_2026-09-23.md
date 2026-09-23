# N3 immutable multi-page voxel block shadow

The one-page `NativeEffectiveVoxelBlock` intentionally rejects a Voxel Tools
block that crosses a 280-cell shaping-page seam. Widening `WorldSourcePin`
would weaken its exact one-primary-page identity and existing query contract.
`encode_native_multi_page_voxel_block` instead accepts one source definition,
one pinned world-delta snapshot, one complete coherent set of ready shaping
page pins, and one block request. It enumerates the **actual** X/Z sample
coordinates at the requested LOD, groups by owning page (including skipped
pages at high LOD), constructs page-scoped source pins sharing that delta
snapshot, calls the already-oracled one-page byte encoder, and stitches one
ZXY SDF16/indices8/data5 result. Its digest binds the request, source,
delta, registry identity and ordered per-primary pin identities.

The focused linked suite passes 7/7. It covers negative and positive X/Z
seams, both axes, LOD page skips, durable edits on opposite sides, repeated
identity, malformed dimensions/LOD/overflow, and empty/missing/extra/duplicate,
not-ready, foreign-source and mixed-registry dependency sets. Focused LLVM
coverage is 140/140 lines, 9/9 functions and 70/70 branches. The aggregate
`artifacts/native-world-backend/n3-multipage-n4-conifer-reduction-01/report.json`
passes 473/473 debug and release tests, editor/release adapter smokes and
100% pure-core coverage (10,720 lines, 1,441 functions, 6,324 branches).

This verifies native page ownership and stitching against the independent
one-page Godot byte oracle; the multi-page test's per-cell reference is the
same native one-page encoder, not an independent full crossing-block Godot
fixture. A full crossing-block VoxelBuffer byte differential remains required.

The function cannot prove that separately supplied registry, town overrides
and delta snapshots were captured at one instant. Production admission must
pin them under one owner/manifest epoch (or sequence-check and retry), retain
pending shaping requests, and reject stale results against the current seed,
owner generation, delta, shaping and town identities before publication.
`VoxelTerrainGenerator._generate_block` returns synchronously and cannot
publish fake air while shaping is pending. A prewarm/retryable demand path and
measured task/admission budgets must precede live use. The current shadow
adapter remains one-page only; no GDScript generator, Voxel Tools collision,
save or navigation authority is replaced or deleted. N3 remains open.
