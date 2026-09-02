# Citadel integration into ordinary gameplay

## Scope and decisions (2026-09-02)

Work on `codex/citadel-visuals-clean`, starting at `794fc4f`. Preserve the
Golden Alley / Solitude-inspired recipe, furniture placement and visual source.
Use ordinary world terrain, streaming, tree publication, player doors and save
deltas. Do not restore the removed Citadel NPC/navigation integration, create
a second route authority, or make residents a prerequisite for building the city.

The user accepted the normal-game trees' slow-render appearance after the fresh
`atlas-34217915` tree diagnostic. This is a product sign-off, not evidence that
all tree species, rendering stages or exit resource leaks were verified clean.

### Explicit baseline exception

Before edits, the unchanged NPC scene was run headlessly, seed `atlas-1492`,
time mode `both`, through the existing process-owning scene watchdog.
Reports: `artifacts/citadel-runtime-integration/baseline-2026-09-02/`.

- `contract-both`: 84 results, no assertion failures.
- `motor-both`: 48 results, no assertion failures.
- `nav_world-both`: 84 results, no assertion failures.
- `route-both`: 130/132 results passed (332 assertions recorded). The diagnostic home collision-lattice
  detour exhausted its 32,000 microsecond budget after four visits, in both modes.
  The route log also contains String/`has_method` script errors and off-tree
  transform errors. Green assertions do not overrule these errors.
- Further suites and headed baseline runs were stopped. No full NPC baseline
  pass or live NPC regression is claimed. All four owned process jobs emptied.

After the critic rejected readiness, the user explicitly authorized proceeding
with these pre-existing failures recorded, leaving their repair for later.
This exception does not authorize changing protected navigation or weakening
tests, and does not waive new integration failures.

## Checkpoints

1. **Shared source preparation:** extract the exact reviewed castle + urban
   composer sequence into a production API. Both visual review and the build
   job consume its prepared furniture and interior data. Prove exact ordered
   source equality and failure/reuse isolation. No live-world completion claim.
2. **Deterministic sites and terrain:** derive placement/reservation from
   immutable seed/recipe inputs before affected terrain publication. Distinguish
   enclosing bounds from actual support/clearance; preserve edited terrain and
   avoid tutorial towns and other sites. Never depend on query order or known-seed
   prewarming. Invalid generated layouts must be reported, not silently repaired.
3. **Ordinary publication/lifecycle:** StructureSystem owns activation through
   a composed service; use the existing building/furnishing publishers, shared
   TreePublicationQueue and shared doors. Keep pending work retryable; budget
   publication; cancel/unload symmetrically. No Citadel-specific tree spawner or
   route service. Resident behavior remains outside this initial integration.
4. **Real-game acceptance:** critic-approved Main menu -> New Game, physical
   player approach/gate traversal, visual preservation, ground continuity,
   departure/re-entry, save/Continue with durable edits, and traversal performance.
   Use fresh reports, traces and inspected screenshots. A relocated observer or
   source-only test is not acceptance for a continuous approach.

Critic approval is required for each checkpoint and before headed launches.
Commit verified focused chunks. Keep the temporary physical-publication bypass
explicit until separately resolved; do not silently turn it into a passed gate.

## Current work

Checkpoint 1 is independently critic-approved: shared source preparation only.
No terrain, streaming, NPC,
navigation, tree-renderer, door, save or building/furnishing recipe changes have
been made by this integration checkpoint. Citadels are not yet spawned by
ordinary New Game. Derived terrain footprints are deliberately deferred to
checkpoint 2; a bounding rectangle must not masquerade as grounding evidence.

Prepared building/furniture data remains in the reviewed local coordinate
system. The build job no longer independently rebuilds compound furniture with
a world-origin offset or requires a residence manifest. World placement must
apply its transform once through publication; this checkpoint creates no
resident, terrain support, or world-position authority.

### Source verification schedule

The first monolithic five-build test (`source-preparation-01`) was intentionally
stopped after measurement showed that one source build takes several minutes.
It has no completed report and is not acceptance evidence. Its watchdog records
the requested forced stop (exit 126), successful Job Object termination, zero
remaining owned members and no unresolved cleanup. `cleanupPassed=false` is
retained; it is not relabeled as a naturally completed run.

The replacement schedule removes the redundant direct-API build. The actual
fixture and worker both call that API. A reference phase freezes the former
sequence's complete typed handoff to an immutable binary file. Consumer phases
verify its hash, seed/context, engine and script-source identity before comparing
complete snapshots, furnishing reservations and diagnostics.

Reproduction from this worktree, with fresh absolute output directories:

```powershell
./tools/run-citadel-recipe-preparation-contract.ps1 -Phase reference -OutputDirectory "$PWD/artifacts/citadel-runtime-integration/source-reference-01"
./tools/run-citadel-recipe-preparation-contract.ps1 -Phase fixture -ReferenceDirectory "$PWD/artifacts/citadel-runtime-integration/source-reference-01" -OutputDirectory "$PWD/artifacts/citadel-runtime-integration/source-fixture-01"
./tools/run-citadel-recipe-preparation-contract.ps1 -Phase worker -ReferenceDirectory "$PWD/artifacts/citadel-runtime-integration/source-reference-01" -OutputDirectory "$PWD/artifacts/citadel-runtime-integration/source-worker-01"
```

Reference/fixture each contain one full build and have 450-second external caps.
Worker contains two full builds on the same reused job, separated by an invalid
request, with a 900-second cap. This is source-contract scheduling, not a runtime
frame-budget or loading-performance pass. Logs are `stdout.log` (stage progress)
and `stderr.log`; `report.json` and `watchdog.json` record results and cleanup.

Acceptance requires all three stages, not a reference capture alone. Coverage
is one seed (`237207443`) at scale `1.25`, actual consumer source equivalence,
invalid-scale input and completed-job reuse. It does not prove cancellation,
concurrent dispatch, builder-null/downstream-composition failure sanitation,
envelope rejection, other recipe contexts, or live publication isolation.
Zero/omitted-scale compatibility currently has static inspection only.

### Evidence recorded so far

- `source-reference-01`: 23/23 checks, 289.345 seconds, 4,649 parts and 146 furnishings;
  complete lossless reference capture, empty stderr, natural exit 0 and owned
  process zero. The binary artifact is 6,843,080 bytes, SHA256
  `f949a4bcacdaf0c5e5fec060979f16eac1012493fe3a30e1a62b2a5a172f8aa2`.
  This phase was launched directly through the scene watchdog with the same
  scene, environment and cap exposed by the reproduction wrapper above.
- `source-fixture-01`: 69/69 checks, `complete`, `fullArtifactsCompared` and
  `passed` true; 352.501 seconds, exact reference hash, empty stderr, natural
  exit 0, clean watchdog and owned process zero. This exercises the actual
  review wrapper calling the production API, not merely a source scan.
- `source-worker-01`: 102/102 checks, `complete`, `fullArtifactsCompared` and
  `passed` true; 638.710 seconds, exact reference hash, empty stderr, natural
  exit 0, clean watchdog and owned process zero. Both successful builds use the
  same job around an invalid-scale request; the retained first snapshot also
  remains exact. Final global Godot process count was zero.

No headed test has been launched for this source-only checkpoint. The multi-
minute cold preparation cost remains visible; running it on a worker does not
constitute an acceptable normal-world streaming/load-latency result.

The independent critic accepted this narrowed checkpoint after inspecting all
three reports, logs, watchdogs, the reference hash and the final diff. The review
approved a focused commit, not world integration or runtime readiness. World
hooks remain pending the user's standalone-landmark versus town-upgrade choice;
standalone landmarks are recommended to preserve existing town/tutorial behavior.
