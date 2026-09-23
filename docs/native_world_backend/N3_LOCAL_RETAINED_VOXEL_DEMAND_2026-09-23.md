# N3 local retained voxel-demand invalidation — focused shadow checkpoint

The native adapter previously bound every retained voxel ticket to the whole
terrain-delta revision and full shaping-registry identity. A durable edit or
site resolution anywhere retired every prepared/published block. This change
binds a queued block to the same ordered, page-local physical-content identity
used by the native multi-page voxel encoder. It is computed from the already
pinned capture pages, not by rebuilding shaping snapshots for every receipt.

The adapter retains the exact shaping dependency page keys for each bound
block. A committed typed/durable transaction's authoritative
`affectedSections` invalidates only blocks whose dependency page bounds
intersect an affected section in X/Z. This is conservative across all Y and
within a dependency page. The ticket generation changes and old results and
receipts are removed before the commit returns. Prepared/insertion/mesh
receipts check the retained generation and pin without regenerating pages.
The owned worker retains its global source/delta/registry capture recheck:
an unrelated edit during encoding may cause that job to retry, but no longer
retires unrelated *retained* block demand.

`apply_shaping_resolutions` admits only terminal decisions. A block is bound
only after all its shaping dependencies were ready; newly resolved regions
therefore cannot alter its captured page content. A replay of an existing
terminal decision is `no_change`; conflicting replacement is rejected by the
registry. The current adapter exposes no registry-retirement endpoint. Pure
core retirement intentionally makes a former ready page unresolved while
preserving old immutable pins; any future adapter retirement endpoint must
invalidate intersecting bound demand before accepting publication. The only
terrain-state mutation in the adapter is `commit_typed_cell_request`, called
by `commit_typed_cells` and `commit_durable_cells`; both now use the same
affected-section invalidation. Initialization creates a fresh one-shot owner.

Focused command: `node tools/run-n3-local-retained-voxel-demand.mjs`.
Report: `artifacts/native-world-backend/n3-local-retained-demand-1790167723582-3295ccac/report.json`.
Owned-process proof: `artifacts/node-tools/process-runs/godot-xUutch/watchdog.json`.
The debug SCons build exited zero; a second invocation reported the target
up to date. Built and installed debug DLL SHA-256:
`8DC446D1257FA6C1928240ECEE9C01CC2E85C46D29143A14CDAB352814B3C753`.

The Godot binding service contract passed. A distant shaping resolution and
terminal replay preserved an already prepared block. A far durable edit left
that block's exact native bytes and local identity unchanged and accepted its
mesh receipt; an edit in its dependency pages rejected the old receipt and
the retained key retried with a newer generation and the edited exact bytes.
All 27 halo keys reached service-level publication, then a second far edit plus
invalidation took 216 microseconds on this sparse two-edit snapshot. This is
one observed sample, not a high-percentile or loaded-save performance bound.

This change is not N3 production cutover or Gate 5 evidence. It does not prove
live VoxelTerrain insertion, mesh/physics receipt correctness, loaded-save
scaling, or headed gameplay. The adapter still caps its whole retained queue
at 128 entries, insufficiently sized for a normal production viewer radius
plus vertical extent. It must be measured and increased or partitioned before
production use. The affected-section loop is bounded by admitted edit batch
and retained keys, but needs stressed-save/high-percentile profiling before
the gameplay frame budget can be claimed. The current page-local identity may
also invalidate a block after an edit elsewhere in its dependency page even
when its packed bytes are unchanged; it is deliberately not an exact byte
cache key.
