# Reuse unchanged party-wall structural proofs

Baseline: clean `codex/citadel-visuals-clean` at `ee51a8e`.
Active goal remains ordinary citadel spawning; this checkpoint is not acceptance.
No protected NPC/routing/movement/navigation file is changed.

## Measured blocker

Public Recipe11, world `atlas-30895044`, region(-1,0), recipe541151883,
forest/scale1.25, stopped cooperatively at its unchanged450s source limit.
The previous geometry failure was passed. Party-wall callback intervals alone
accounted for75.876s before cancellation; maximum callback gap19.077390s.
These are source-worker interval measurements, not gameplay-frame timings.
See `CITADEL_STREET_KEEP_BOUNDARY_2026-09-03.md` for exact command and artifacts.

The completion stage obtained a whole-source physical report, then the party-wall
planner copied and fully validated that same source again for every declaration.
It could then perform another full proof with the declaration removed before
discovering that no finite candidate contact existed.

## Implementation

- A process-local typed proof context binds exact source bytes, resolved proof
  bytes, report bytes, invalid-gable state and part-index identity. Reuse rejects
  stale sources or changed proof artifacts. The context never enters a blueprint,
  save, runtime publication record or persistent/global cache.
- The completion stage reuses the context across unchanged failed/no-op plans,
  invalidates immediately after an applied repair, and rebuilds before the next
  failed-ID decision. It reports bounded build/reuse/invalidation/proof counters.
- Every potentially successful plan retains its separate full proof with the
  entire facade declaration removed. A facade cannot prove its own support.
- A rejection-only geometry precheck tests the first sorted failed-bottom target
  against a conservative seat superset. It does not filter on rootedness or
  resolved physical intent. No finite contact returns the original failure reason
  and first target ID; any possible contact proceeds to independent validation.
- Source bytes are pinned before entry callbacks. Ordinary pending results also
  recheck bindings. Completion callbacks cannot turn source mutation into an
  accepted or skipped declaration. Cancellation discards unfinished proof work.

The critic identified and required repairs for early-return mutation checks,
post-apply invalidation ordering and entry-callback mutation before a skipped
declaration. Tests retain those cases explicitly. No timeout, structural support
rule, geometry, seat ranking or acceptance threshold has been relaxed.

## Verification

Artifacts are under `artifacts/citadel-runtime-integration/`. Commands use the
owned-job `tools/run-building-contract.ps1` with fresh output directories.

```powershell
./tools/run-building-contract.ps1 -Contract MasonryPartyWallProofArchiveReplay.gd -OutputDirectory artifacts/citadel-runtime-integration/party-wall-archive-01 -ReportEnvironment PARTY_WALL_ARCHIVE_REPORT -TimeoutSeconds 45
./tools/run-building-contract.ps1 -Contract MasonryPartyWallProofReuseContract.gd -OutputDirectory artifacts/citadel-runtime-integration/party-wall-reuse-01 -ReportEnvironment MASONRY_PARTY_WALL_PROOF_REUSE_REPORT -TimeoutSeconds 45
```

Archive01:15/15,24.206986s. Actual historical input SHA
`7e9dae37309cdc1e7637c0769df20da9b96a6c6e66c9a7a3731617dc266e0afe`,
expected output SHA
`c5c1cb9fffe3016e4d5a27b6d0ab8683db61e4b2066d4cda34906e293d3b43dc`.
Typed changes, target IDs and entire resulting blueprint exactly match the
previous approved result. Independent proof runs once. This predates the final
entry-callback guard and geometric precheck and is not final-source evidence.

Reuse01:47/47,0.076889s. Explicit small synthetic masonry fixture through actual
physical/declaration APIs; successful cached/uncached equality, independent
root/circular rejection, stale/tampered contexts, cancellation and completion
invalidation counters. It predates the rejection-only precheck and additional
direct no-op mutation controls. Neither run establishes a full-build speedup.
Both completed naturally with exit0, clean logs, no timeout/forced cleanup and
authoritative owned zero.

The rejection oracle is the original `ee51a8e` recipe, LF-normalized into
`party-wall-frozen-original/MasonryPartyWallBearingRecipe.gd`, SHA
`7e76cdd46d12b6c159787428135763c3838ff6c43147078063b7133bf3a1202b`.
It is loaded only by the offline contract, never by production. Historical
snapshots are also offline evidence, not injected into game spawning.

Current-source checks:

```powershell
./tools/run-building-contract.ps1 -Contract MasonryPartyWallProofArchiveReplay.gd -OutputDirectory artifacts/citadel-runtime-integration/party-wall-archive-02 -ReportEnvironment PARTY_WALL_ARCHIVE_REPORT -TimeoutSeconds 45
./tools/run-building-contract.ps1 -Contract MasonryPartyWallProofReuseContract.gd -OutputDirectory artifacts/citadel-runtime-integration/party-wall-reuse-02 -ReportEnvironment MASONRY_PARTY_WALL_PROOF_REUSE_REPORT -TimeoutSeconds 45
```

Archive02: 15/15, 19.626894s, exact historical plan and complete output snapshot.
It includes the final plan entry guards and rejection precheck. Its single
explicit recipe hash is not a full dependency-closure audit. The later stage-only
terminal-cancellation guard is exercised by Reuse02, not by this plan replay.

Reuse02: 62/62, 0.125624s, 46 unchanged dependency hashes. The frozen original
implementation returns byte-identical successful and geometrically disjoint
rejected plans. Disjoint geometry skips only the independent proof; plausible
but unrooted and circular seats still undergo that proof and fail. Direct no-op
source/report mutation, prefilter cancellation/mutation and stage cancellation
are rejected, with zero callbacks after a cancellation. The final fixture SHA is
`05f041318989bd8013b067d3b594af2e09b766b80e88849e44c99a72e9592dcc`.

Both current runs exited naturally with code0, clean logs, no timeout/forced
cleanup, and authoritative zero remaining owned processes. Reports are
`report.json`/`report.bin`, logs and `watchdog.json` in each named directory.
These are source/contract checks, not full-build speedup or gameplay acceptance.
Critic approval and the same bounded full public Recipe run remain required
before any headed launch or integration-completion claim.

## Full candidate Recipe12

Hooke approved the frozen source-only launch, not a headed run:

```powershell
./tools/run-citadel-candidate-recipe-diagnostic.ps1 -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-12 -ExpectReady -CandidateRegion '-1,0' -ExpectedRecipeSeed 541151883 -Seed atlas-30895044
```

**Failed by cooperative cancellation**, source450.161532s. The original450s
source,60s independent-proof and540s outer deadlines are unchanged. The full
party-wall stage finished; cancellation was later, during the initial threshold
physical proof. No ready blueprint or independent final physical pass exists.

Party-wall start398556361usec to bracket-retry start430770976usec measures
32.214615s for the complete stage. There was one source proof, eight attempted
plans, eight completed-plan callbacks and no independent-proof callbacks. All
35456 prefilter seat visits completed; potential successful support was never
certified by skipping independent proof. Recipe11 spent75.876s in its old
party-item callback intervals without completing the stage. These different
interval scopes establish progress, not a claimed total-build speedup ratio.

The full source still has148.600s attributed to initial compound placement
structure proof and162.71s to physical support resolution across stages. Those
are callback intervals, not exclusive CPU or frame timings. Maximum callback
gap is3.201856s, down from19.077390s in Recipe11; this is a worker diagnostic,
not a gameplay-frame budget pass.

`report.json`, `timings.json`, `progress.json`, `failure.bin`, engine logs,
`source-hash-audit.json` and `watchdog.json` are preserved in the named directory.
The terminal report overrides the final pre-cancellation progress snapshot.
Natural exit1, empty stderr, no forced cleanup, no outer timeout, authoritative
zero owned processes and empty final membership. All763 source hashes and
the input context remained unchanged. Failure BIN SHA:
`0e2e56469ada79fd10ac87b45addfbc04b2434439788c40bfc6c4b7caf624bda`.

No headed launch occurred. Overall in-game spawning remains incomplete.

Hooke independently returned **PASS for the focused five-file proof-reuse
commit**, after reviewing the current code,62/62 and15/15 evidence and failed
Recipe12 accounting. This is not full-source, budget, headed or spawning approval.

The next read-only finding is repeated candidate-shape validation in
`CastleCourtyardDistrictPlacementPlanner._validate_exact_constraints`: each
single-obstacle call to `composition_overlaps_obstacles` revalidates all candidate
parts before aggregate rejection. A candidate-local validated view may remove
that repetition while retaining the same overlap kernel, callbacks, counters
and rejection order. Savings are unmeasured; this is not implemented or accepted.
