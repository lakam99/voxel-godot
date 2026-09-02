# Cancellation within private physical proofs

## Scope

Continuation of `c91fe1c` on `codex/citadel-visuals-clean`, starting from a clean
worktree. Goal remains ordinary-game citadel spawning; this is a worker-exit
prerequisite, not live spawning or headed acceptance. The previous actual
cancellation took 7.921 seconds while waiting for one entire physical proof.

`BuildingBlueprint.validate_physical_integrity_cancellable(continuation)` and
the existing zero-argument validator drain the same implementation. The old
public signatures and default virtual resolve/index dispatch stay intact.
Supplied continuations operate on exclusively owned base Blueprint proof copies;
they do not replace subclass-specific validation. Same-instance callback
re-entry is outside this private-worker contract.

Cancellation is checked between schema/classification/root/support work for
individual parts, during grid insertion at most every 64 cells, before each
part/frame verdict and around aggregate dependency propagation. Successful
geometry math, ordering, report shape and post-proof recipe facts are unchanged.
The callback is never serialized into source policy, snapshots or saves.

A rejected continuation unwinds immediately with `passed: false`,
`cancelled: true`, zero checks and an explicit cancellation violation. Temporary
owned caches/indexes are cleared. It does not roll back partially derived recipe
facts: the private proof copy is discarded and a retry starts from authoritative
input, not from the cancelled copy. Structural, opening-head and lower-facade
callers now discard cancelled proofs before interpreting their checks, emitting
partial snapshots, counting a geometric rejection or calling the callback again.

## Evidence

All runs below are headless and use the process-owning watchdog. Artifacts are
under `artifacts/citadel-runtime-integration/`; each `watchdog.json` contains the
exact command and cleanup evidence. No NPC/navigation change or headed test is
part of this chunk. Existing NPC baseline failures remain explicitly deferred.

- `building-validation-cancellation-03`: 465/465 source/service checks over
  61 cancellation cases on small synthetic fixtures using real proofs. Covers
  all 12 checkpoint labels, first-false termination, late/entry cancellation,
  prepopulated-index cleanup, discarded-copy lifetime, default/empty/true
  complete-output parity and legacy virtual dispatch. This is not old/new
  frozen-input evidence or live gameplay.
- `physical-cancellation-cache-01`: unchanged cache regression passes 75/75,
  including legacy overridden resolve dispatch and nested cache ownership.
- `physical-cancellation-differential-01`: all 13 checks pass on the actual
  4,703-part prepared candidate. Old `c91fe1c`, current default and current
  always-true validation produce byte-identical complete reports and complete
  post-proof snapshots, with no normalization. All three pass and release their
  caches. Input hash is bound to `actual-site-source-05/result.bin`; source
  dependencies remain unchanged. The old script was independently checked
  against Git with only its global class name removed and line endings
  normalized; archived SHA256 is
  `1360a1ffb30aff7893e3246a43646e9793cee354a77cea6b3916dc99682c4051`.
  Measured proof durations were 12.170/11.444/10.180 seconds. These overlapping
  source runs are not an isolated speed benchmark. The enabled proof's largest
  observed callback interval was 21.384 ms, in final dependency propagation;
  there is no zero-atomic-over-8-ms claim for this worker-side source operation.

- `site-structural-cancel-02`: actual Queue -> Site -> Source, `atlas-1492`,
  region `(1,-3)`, scale 1.25. An observation-only wrapper arms on lower-facade
  initial proof, then main requests cancellation during its real support
  resolution. No substitute construction, injected delay or semaphore hold.
  Passes 9/9. First rejecting checkpoint is recorded **2.652 ms** after the
  request, sanitized Site return at **133.623 ms**, and joined source/result
  at **137.659 ms** (previous whole-proof wait: 7.921255 seconds). Source itself
  returns cancelled without blueprint/furniture, not just a suppressed queue
  result. Consumed once, retirement drained, clean natural exit 0 and owned zero.
  Caller cancellation costs 5 microseconds; externally timed polling peaks at
  482 microseconds. This demonstrates this proof-phase improvement, not a
  whole-build shutdown deadline.

- `site-build-queue-real-03`: full actual Site preparation for the same candidate
  passes 8/8. Total runner elapsed is 363.559 seconds, including artifact
  comparison. Complete authoritative output remains exact against
  `actual-site-source-05`, excluding only root `preparationUsec` and the same six
  survey scheduling/timing fields documented previously. All geometry,
  furniture, access reservations, profiles, manifests and source identities
  remain compared. Output SHA256 is
  `c91ba92117cce5da4940042750069753fff59c587a551eec86cbabcf0835b013`.
  Source/input hashes stable, 17,552 owner polls, internal maximum 132
  microseconds, immutable consume-once result and drained shutdown. These runs
  overlap other tests; no total-generation speed improvement is claimed.
- `completion-cancel-04` and `completion-parity-04`: existing completion-caller
  contracts pass 84/84 and 61/61 in 42.033/46.976 seconds. Only consecutive
  identical progress-log writes were coalesced; full callback traces and all
  assertions remain intact. 78,364/112,944 observed callbacks produced
  1,217/2,842 progress entries. Cancellation stays terminal through the callers,
  and omitted/empty/true success outputs remain exact.

All final runs above have empty error logs, natural exit 0 and authoritative
zero owned processes. The first new unit-run attempt is retained under
`building-validation-cancellation-01`: a test-only inferred-type parse error
exited immediately with exit 1, clean cleanup and owned zero. Attempt 02 passed
448 checks, then attempt 03 added explicit base-instance and complete stage
coverage. Neither failed evidence nor test assertions were suppressed.

Reproduction uses fresh output directories:

```powershell
./tools/run-building-validation-cancellation-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/building-validation-cancellation-03 -AuthorizeLaunch -TimeoutSeconds 60
./tools/run-citadel-completion-cancellation-contract.ps1 -Phase cancellation -OutputDirectory artifacts/citadel-runtime-integration/completion-cancel-04 -AuthorizeLaunch -TimeoutSeconds 60
./tools/run-citadel-completion-cancellation-contract.ps1 -Phase parity -OutputDirectory artifacts/citadel-runtime-integration/completion-parity-04 -AuthorizeLaunch -TimeoutSeconds 60
```

The actual Site/differential runners and their exact watchdog invocations are
preserved in their artifact directories. They require the recorded immutable
input artifacts; they are not replaced by a synthetic fixture on replay.

The independent critic approved this focused source-proof cancellation commit
after code review and verification of the final reports, current hashes, exact
preservation, real cancellation, legacy dispatch and process cleanup. Approval
does not include live spawning, headed readiness or a hard shutdown bound.

## Remaining boundary

These checks do not make every source phase cancellable. Initial compound
construction, retained paving and other composition stages still have long
uninterrupted intervals. Individual per-part graph recursion and aggregate
dependency propagation also remain synchronous; cancellation timing is measured,
not a universal hard deadline. Native terrain admission, ordinary publication,
streaming/re-entry, saves, physical player traversal and visual/runtime
acceptance remain unfinished. No live caller is enabled by this patch.
