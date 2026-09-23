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
delta, registry identity and ordered per-primary pin identities. That digest
is currently a **shadow transport/freshness identity**, not a production
content-cache key: its global delta and registry revisions make unrelated
edits invalidate it. A separate local block-content identity must derive
from the ordered page-scoped content identities, with global revision and
owner generation carried separately for publication admission.

The next shadow change adds `blockContentIdentity` alongside `pinIdentity`
for one-page and multi-page encoders. It hashes source identity, the admitted
block request and ordered page-scoped physical identities, omitting global
delta/registry sequence values. This is conservative **page-local source
content**, not a hash of the exact packed bytes: an edit elsewhere in a
dependency page may change it while this block's bytes stay unchanged.
Focused tests were added for far-page invariance, same-page conservative invalidation,
local seam-edit invalidation and single-page/multi-page equivalence. The
global revision-bearing pin remains mandatory for stale-result rejection.
The final combined gate for this addition is
`artifacts/native-world-backend/n3-local-content-n4-conifer-schema-01/report.json`:
480/480 debug and release tests, adapter smokes, 10,936/10,936 pure-core
lines, 1,459/1,459 functions and 6,424/6,424 branches pass.
The post-build focused Godot adapter contract at
`artifacts/native-world-backend/n3-local-content-shadow-01/report.json`
also passes the new local-content-identity invalidation check, with an owned
process exit of zero and no cleanup residue.

The focused linked suite passes 7/7. It covers negative and positive X/Z
seams, both axes, LOD page skips, durable edits on opposite sides, repeated
identity, malformed dimensions/LOD/overflow, and empty/missing/extra/duplicate,
not-ready, foreign-source and mixed-registry dependency sets. Focused LLVM
coverage is 140/140 lines, 9/9 functions and 70/70 branches. The aggregate
`artifacts/native-world-backend/n3-multipage-n4-conifer-reduction-01/report.json`
passes 473/473 debug and release tests, editor/release adapter smokes and
100% pure-core coverage (10,720 lines, 1,441 functions, 6,324 branches).

The additional `NativeWorldBackend.encode_voxel_block_shadow` adapter accepts
a bounded request, pins one world-delta snapshot, resolves the complete
shaping dependency union and rechecks source/delta/registry freshness before
returning bytes. The focused Godot contract report at
`artifacts/native-world-backend/n3-multipage-focused/shadow-report.json`
passes. It directly compares all three packed channels against
`VoxelTerrainGenerator._generate_block` across one unedited negative X/Z page
seam. Two durable cross-seam edits are checked against native per-page bytes,
material lanes and revision identity, not against a fresh edited Godot buffer.
A positive seam and a ready page stitch are also tested. A distant LOD-10
request correctly returns pending
for unresolved shaping instead of returning fake air; only the pure core has
ready skipped-page stitching coverage so far.
The subsequent combined native gate at
`artifacts/native-world-backend/n3-multipage-n4-conifer-worker-02/report.json`
passes 477/477 debug and release tests, adapter smokes, and exact pure-core
coverage of 10,887/10,887 lines, 1,457/1,457 functions and 6,412/6,412
branches. An initial gate was blocked only by newly uncovered delta-pin and
grammar-default branches; focused unit cases closed those gaps without
weakening thresholds.

The function cannot prove that separately supplied registry, town overrides
and delta snapshots were captured at one instant. Production admission must
pin them under one owner/manifest epoch (or sequence-check and retry), retain
pending shaping requests, and reject stale results against the current seed,
owner generation, delta, shaping and town identities before publication.
`VoxelTerrainGenerator._generate_block` returns synchronously and cannot
publish fake air while shaping is pending. A prewarm/retryable demand path and
measured task/admission budgets must precede live use. The current shadow
adapter is serialized and is not a Voxel Tools worker callback; it has no
concurrent-worker safety claim. No GDScript generator, Voxel Tools collision,
save or navigation authority is replaced or deleted. N3 remains open.
