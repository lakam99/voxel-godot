# N3 composed terrain runtime owner checkpoint

`NativeTerrainRuntimeOwner.gd` is an inert cutover component; it is not yet
installed in `VoxelTerrainRuntime`. It requires a `VoxelTerrain` with no
generator and automatic data loading disabled before setup. It builds the
native save-v2 initialization request from
`NativeWorldSourceRequest.from_main_with_current_volume`, initializes one
`NativeWorldBackend`, and binds that same instance to
`NativeShapingPageAdmission`, `NativeTerrainBlockPublisher`,
`NativeTerrainCellSource`, and `NativeTerrainNumericSource`. One
`NativeTerrainDemandPlanner` feeds bounded desired-set deltas to the publisher
through one stable native consumer ID.
There is no script generator or gameplay cell-query fallback in this owner.

The owner now exposes a fail-closed adoption seam for the staged loading
transaction. `setup_from_committed_transaction` validates the transaction's
ready/committed receipt, positive import generation, exact backend instance,
valid producer snapshot lease, full native source identity and production seed,
then consumes the backend
through the transaction's single-use `take_backend` operation. Independently
passing a backend and caller-authored receipt is not supported. A lease revoked
after commit but before transfer cannot activate an owner: the boundary consumes
and explicitly releases that committed backend. The physical
source identity remains an additional invariant, not a claimed digest of the
durable edit payload.

Artifact request ownership no longer assumes that a Godot `ObjectID` is a
positive signed integer. A monotonic process-local allocator issues distinct
positive owner generations and fails closed instead of wrapping at exhaustion;
this removes a nondeterministic setup failure without folding two opaque object
IDs onto the same token.

`advance()` progresses the existing Citadel source admission, applies at most
one acknowledged planner delta, and pumps native block publication. Failed
source or publication state is terminal for further advancement; the caller
must keep gameplay/loading fail-closed and call `stop()`. Stop marks all
publisher blocks for retirement and repeatedly requires physical unload
before releasing native requests. `drain_step()` retains the backend until
the publisher reports no outstanding native work, then drops all owned
references. The production runtime still owns safe viewer removal, engine
block unload, and an explicit retry loop if stop is pending.

Focused service fixture: `node tools/run-n3-terrain-runtime-owner.mjs` passed
in `artifacts/native-world-backend/n3-terrain-runtime-owner-1790206101790-14ba8358/report.json`
(owned-process receipt:
`artifacts/node-tools/process-runs/godot-Pp1ehd/watchdog.json`). It uses a
production-shaped `MainCore`, `StructureSystem`/Citadel admission,
`WorldGenerationSystem`, and `TerrainVolumeService` with a durable edited
cell. It verifies automatic-loading setup rejection, one initialized native
source identity, durable edited-cell and numeric/projection reads through
the shared native backend, 27 data-block halo demand handed to the publisher,
backend reference retirement after stop. Focused owner and staged-load contracts
now cover a real transaction-to-owner adoption, single-use replay rejection,
cross-transaction receipt rejection, post-transfer source validation cleanup,
and revoked-lease rejection at commit and transfer. This remains service-level
native binding evidence, not headed gameplay,
visual collision, streaming performance, or N3 cutover. The project compile
smoke also passed with owned-process receipt
`artifacts/node-tools/process-runs/godot-Ai5ZTY/watchdog.json`.

The staged transaction evidence is
`artifacts/native-world-backend/n3-main-load-transaction-1790206087871-760f9764/report.json`
(owned-process receipt
`artifacts/node-tools/process-runs/godot-n01Pwg/watchdog.json`). Its lifecycle
record includes the successful committed-owner adoption and the explicit
`leaseRevokedTransferRejected` result.

Remaining integration: atomically replace the script generator and automatic
loading in `VoxelTerrainRuntime`, feed real primary/secondary/retained/
foreground demand and vertical bounds, keep over-cap proposals retryable,
mirror post-setup edits and cell-query consumers to this owner, and validate
engine mesh/physics receipts with a headed main-menu playtest. The same
backend must own save/Continue and reset; no parallel source can remain.
