# N3 staged main-load initializer design

Status: focused transaction milestone; not a production cutover or N3 completion.

## Ownership and call contract

`NativeTerrainLoadTransaction` stages one `NativeWorldBackend` save-v2
candidate. It does not install terrain, register a `WorldGenerationSystem`
facade, publish collision, or release gameplay. The expected future owner flow
is:

1. Decode one canonical save-v2 snapshot into a fresh, exclusively owned
   value tree. Transfer that tree to the transaction lease; do not retain any
   writable aliases or allow SaveSystem/autosave/edit code to mutate it until
   transfer or acknowledged drain.
2. Build the small world-source descriptor with
   `NativeWorldSourceRequest.from_main_with_v2_save_snapshot(main, save)`.
   The returned `request.terrainVolume` borrows the save's exact volume value;
   retain the returned `snapshotOwner` lease.
3. Start the transaction with
   `transaction.start(request, max_records_per_advance, snapshotOwner)`.
   New Game uses `NativeWorldSourceRequest.from_main(main)` and stages an empty
   volume at revision 0 through the same native transaction.
4. Call `advance()` on the loading coordinator over frames until it reports
   `candidate_requires_explicit_commit`. Each accepting advance submits no
   more than its configured record quantum. The allowed maximum is 256 because
   that is the native adapter's `DEFAULT_MAX_RECORDS_PER_APPEND`; callers may
   select a smaller quantum. This bounds record count, not elapsed time.
5. Compare/approve `candidate_source_identity()` at the owner boundary, then
   call `commit(expected_identity)`. A mismatch is rejected before consuming
   the C++ one-shot commit right. A successful commit checks the backend's
   current source identity and leaves the imported terrain privately held by
   this transaction.
6. Call `take_backend()` exactly once and install that backend in the next
   owner. Save-envelope coordination may release the source snapshot only after
   transfer. Installation and physical readiness remain separate obligations.
7. For cancellation or failure before commit, retain the transaction and its
   backend, request cancellation, and keep calling `advance()` until
   `cleanupComplete`/`drained` is reported. The native API owns asynchronous
   finalization and bounded disposal; dropping the backend sooner can force a
   synchronous destructor join or lose the acknowledged cleanup boundary.

`start_backend()` intentionally rejects a preinitialized backend. Accepting one
would bypass the candidate/private visibility and explicit-commit boundary.
After successful commit the load transaction is non-cancellable; the receiving
runtime owner becomes responsible for subsequent source/page/publication
lifecycle.

## Work and thread boundary

The GDScript transaction does not `duplicate(true)` the save volume. The
snapshot constructor copies only the source descriptor/finalized policy and
issues a producer-owned `NativeWorldSaveSnapshotLease` retaining the exact
save and volume. Save-v2 requests without a valid lease fail closed. Before
each admission/finalization step and again at commit, the transaction checks
lease validity, volume identity and the immutable volume revision. The save
producer must call `lease.invalidate(reason)` *before* any nested volume
mutation, and it must not keep a writable alias active during the lease. A
revocation stops further admission and forces cancellation/drain; a candidate
whose lease was revoked cannot commit. The lease is cooperative, not a Godot
deep-freeze: Dictionary/Array are mutable reference values, so transaction
code cannot detect an out-of-contract nested write that bypasses invalidation.
The production Main/SaveSystem integration must therefore transfer a fresh
snapshot with no other mutable aliases and route all writes through the lease
owner. Recursively freezing every nested collection on Main would itself be an
O(save) synchronous traversal, so this stage deliberately does not do that.

Each `advance()` creates a shallow section envelope and a bounded cell slice; the C++ GDExtension parses
the Variant dictionaries, validates typed cell fields, and copies at most 256
records on Main per append call. Thus Main still performs bounded Variant
parsing/copying and incurs one native adapter call per slice. Do not describe
this count cap as a wall-time/frame-cadence bound.

The importer moves its accumulated typed POD builder to the existing private
C++ worker for whole-volume canonicalization and candidate construction. The
candidate remains invisible through `NativeWorldBackend.status()` until the
main-thread explicit source-identity commit. Cancellation during acceptance
abandons and drains bounded record batches; cancellation during worker
finalization retains the backend/input owner through worker completion, join,
and candidate/builder disposal acknowledgement.

The `terrainVolume.revision` is the persisted save-domain revision. On native
initialization the backend's live `terrainDeltaRevision` starts at zero; do not
conflate these counters. `sourceIdentity` identifies the procedural physical
source, not the durable save payload. Ownership/generation and retained snapshot
identity bind the save transaction; source identity alone is not a save-content
hash.

## Focused evidence

The intended focused command is:

```text
node tools/run-n3-main-terrain-load-transaction.mjs
```

Its report is contract/service-level GDExtension evidence only. It must include
bounded record admission, lease-revocation rejection before mixed-snapshot
commit, precommit invisibility, explicit identity mismatch
and commit, exact v2 data preservation through transfer, cancellation during
acceptance/finalization, malformed-input cleanup, stale-generation rejection,
deterministic worker-in-flight cancellation/join/disposal ordering, terminal
drain-failure settlement with owner retention, and owner retention until
acknowledged drain. Timing counters are diagnostic
and do not establish headed responsiveness or production Main New Game/Continue
integration. The broader N3 cutover still has to migrate all runtime callers,
deactivate the GDScript generator/edit authority atomically, and prove loading,
save/reload, terrain/collision and Gate 5 requirements on the final native
build.
