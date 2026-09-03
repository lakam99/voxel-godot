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

The user chose **rare standalone landmarks in any surface land biome**, excluding
ocean and caves. Existing block-built towns, including the tutorial, stay in
place for now; this is not a town replacement/migration. Initial site-field
tuning is 35% occupancy of 2048-cell regions (about one raw candidate per
21.8 square kilometres at 1.35 metres/cell), before eligibility exclusions.
This is a tuning assumption, not measured final accepted-landmark density.

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

The shared preparation worker now supplies all 1,450 masonry descriptors to
ordinary wall publication and aperture preparation. Final actual construction
passes 68/68 with byte-identical available scene facts and clean owned shutdown.
See `CITADEL_WORKER_MASONRY_PREPARATION_2026-09-02.md`. Scene time falls from
32.330 s to 22.484 s and outer calls from 4,682 to 3,254. Background preparation
takes 24.803 s, including 5.355 s of masonry work moved off-frame. Construction
still trails the earlier 21.134 s synchronous baseline; roof, aperture and final
validation overruns remain. Next are those remaining operations and ordinary
activation, not further descriptor tuning. The independent critic approved this
focused checkpoint and commit; no performance, headed or ordinary-spawn approval
is claimed.

Incremental masonry and immutable prepared history now pass the actual-source
construction checks (65/65), with the same available scene facts and clean owned
shutdown. See `CITADEL_INCREMENTAL_MASONRY_PUBLICATION_2026-09-02.md`. Wall
descriptor work is sliced (measured maximum 2.673 ms), and repeated full-history
encoding is removed on the prepared path without weakening mutable validation.
Overall construction is 32.330 s versus the preceding 21.134 s synchronous-wall
baseline: this is still a throughput regression, not a performance pass. Roof,
aperture and final-validation stalls remain. The next chunk should move exact
CPU descriptor work into the existing preparation worker, then complete ordinary
activation and real-game acceptance. The independent critic approved this
focused checkpoint and commit; no budget pass, headed approval or successful
ordinary-world spawn is claimed.

Prepared immutable metadata now removes repeated full-prefix copying from real
scene construction. Final headless construction passes 62 checks in 21.134 s
versus 49.994 s at the incremental baseline, with identical available scene
facts and clean owned-process teardown. See
`CITADEL_PREPARED_METADATA_PUBLICATION_2026-09-02.md`. Compiler controls pass
69/69, flush controls 122/122 and existing lifecycle/paving/masonry controls
remain green; NPC results match the explicitly accepted broken baseline.
The independent critic approved this focused change and commit. Wall publication (40.533 ms), validation
commit (22.533 ms) and masonry setup (11.358 ms) still exceed the budget.
Ordinary service activation and headed/gameplay acceptance remain unfinished.

The incremental paving/mesh/metadata follow-up is implemented and functionally
verified; see `CITADEL_INCREMENTAL_SCENE_PUBLICATION_2026-09-02.md`. Geometry
parity passes 910 checks, ownership/submission controls 62, cancellation controls
117 and final actual construction 61. Available scene facts match the prior
baseline; headless MultiMesh readback cannot prove GPU instance fidelity.
The large paving/copy units are split, but full construction is slower (49.994 s)
and wall/masonry/commit stalls remain. This is not a full performance pass or
ordinary activation. Reducing repeated metadata copying/retention and bounding
the remaining wall/validation work are the next measured performance tasks.

The real building/furnishing publishers and shared tree queue now construct the
complete accepted source through a cancellable scene job in a headless diagnostic.
See `CITADEL_SCENE_PUBLICATION_2026-09-02.md`: final tiny controls pass 65/65 and
actual publication 61/61, including exact blocking collision and resource cleanup.
The earlier failed audit is explicitly invalid, not a green result. Scene
publication still has measured paving/metadata/masonry stalls and is NOT enabled
by the ordinary service yet. Player access/readiness, shared-door cleanup and
live lifecycle/visual acceptance remain open. No headed approval is claimed.

Ordinary streaming preparation is now wired through StructureSystem and native
runtime maintenance, with current-generation admission, cache-eviction reuse,
cancellation, loading/reset drains and combined shutdown. See
`CITADEL_STREAMING_PREPARATION_2026-09-02.md`: worker controls pass 62/62 and
service/lifecycle controls 69/69; existing admission/bootstrap/town-input checks
pass 124/28/52, and native admission/player-collision controls pass 42/42.
NPC results retain the accepted baseline failures and route
stderr is exact to the prior final preparation run. This is preparation only:
scene parts, furniture, trees and doors are not yet installed by this owner,
and no real-game city-spawn or headed acceptance is claimed.

Latest publication work: exact worker-side restoration is committed as
`6919fbe`. Background diagnostic preparation and a one-shot, revision-bound
entry to the existing building publisher are implemented and critic-reviewed.
See `CITADEL_BACKGROUND_PUBLICATION_PREPARATION_2026-09-02.md`: final actual-source
controls pass 67/67; main-thread begin measures 17.321 ms instead of the prior
18.871 seconds. This is not a frame-budget pass: remaining scene preparation,
part publication, ordinary lifecycle dispatch and shared tree/door integration
are unfinished. No city-spawn or headed acceptance is claimed. Existing NPC
assertion failures remain; final route logs contain 250 error headers rather
than 244 due to extra visits in the same known timing-budget diagnostic, as
independently classified by the critic and documented in the evidence report.

Latest: native terrain admission and ordinary-runtime wiring are implemented and
independently critic-approved for this focused checkpoint. See
`CITADEL_NATIVE_TERRAIN_ADMISSION_2026-09-02.md`.
Admission controls pass 124/124, actual-profile consistency 27/27, native
loading/player-collision controls 42/42, bootstrap ordering 28/28 and finalized
town-input/callback controls 52/52. Existing NPC failures remain identical to
the accepted baseline exception. This is not a spawned city: ordinary building,
furniture, shared-tree/door publication and lifecycle remain next, followed by
critic-approved real-game visual/traversal/save/performance acceptance. No headed
approval is claimed. The following entries preserve prior checkpoint history.

Update: source preparation and candidate field are committed; ordinary structure
candidate preservation (`ddea9d6`) and the exact-output physical validation cache
(`6357aa3`) are also critic-approved and committed. The terrain source/mask
boundary passed 33 checks and independent critic review; see
`CITADEL_TERRAIN_SOURCE_2026-09-02.md`. Actual site preparation and runtime
activation remain in progress. The active goal is **continue until citadel
spawns correctly**; no completion or headed approval is claimed.

The subsequent fixed-axis placement repair is committed as `11cf54b`. The
source-only Site preparation/cancellation boundary is critic-approved; see
`CITADEL_SITE_PREPARATION_2026-09-02.md`. Its actual candidate replay still fails
on four structural parts, while the reviewed reference's full geometry and
furniture remain byte-identical. No ordinary-game spawning is enabled yet.

Subsequent retained-paving source integration is committed as `316768d`.
The sign source-placement follow-up now passes the fresh actual candidate's
complete Site preparation (`actual-site-source-05`, 4,703 building parts and
210 furnishings). See `CITADEL_SIGN_SOURCE_PLACEMENT_2026-09-02.md` for the
policy, changed reference-sign boundary and source-only evidence. The full
reference preservation check passed 51/51 and the independent critic approved
this focused source follow-up. Ordinary runtime
activation and headed acceptance remain unfinished; source readiness is not
live spawning.

The owned Site build queue is committed as `be3929d`; see
`CITADEL_SITE_BUILD_QUEUE_2026-09-02.md`. A full real worker preserves the
actual candidate, and queue-owned payload disposal now runs off the main thread.
The subsequent completion-checkpoint follow-up preserves the full candidate and
proves actual source cancellation without returning partial geometry. See
`CITADEL_COMPLETION_CANCELLATION_2026-09-02.md` for focused contracts, commands
and honest timing limits. It replaces the earlier single 232.534-second
structural callback interval with per-house/panel/stage checks, but cancellation
during one inner proof still took 7.921 seconds and initial compound construction
still has a roughly 42.6-second interval. Live dispatch remains disabled until
deep source cancellation, native terrain admission and ordinary publication are
integrated; no gameplay completion or headed acceptance is claimed.

The physical-proof cancellation follow-up now stops inside individual proof
work: the measured actual source cancellation is 137.659 ms versus the earlier
7.921 seconds. Old/current complete proof reports and post-proof snapshots are
byte-exact without exemptions; the full actual Site result is also exact with
only its previously declared timing exemptions. See
`CITADEL_PHYSICAL_CANCELLATION_2026-09-02.md`. Initial compound, retained-paving
and other composition intervals still need cancellation work; native terrain
admission and ordinary runtime publication remain unfinished.

The compound-construction follow-up is independently critic-approved; see
`CITADEL_COMPOUND_CANCELLATION_2026-09-02.md`. Profiling identified courtyard
placement as 37.651 seconds of uninterrupted compound work. Inner placement
checkpoints reduce the final measured largest compound callback gap to 222.905 ms;
an actual final-code worker cancellation returns in 33.357 ms without a partial source or
entering the urban composer. These are cancellation observations, not faster
generation or a universal timing guarantee. All three final build modes and
reused-diagnostics controls preserve complete old compound outputs exactly;
late-cancellation controls also pass. Approval is source-only.
Retained-paving/perimeter source cancellation, native
terrain admission and live publication remain open; no headed run is approved.

Compound cancellation is committed as `d9cb0ce`. The next retained-paving
cancellation follow-up is independently critic-approved; see
`CITADEL_RETAINED_PAVING_CANCELLATION_2026-09-02.md`. Existing source/adapter
contracts pass 21/21 and 17/17. Actual Queue -> Site -> Source cancellation
inside retained validation returns in 56.112 ms, without partial output or
entering structural completion, and shuts down cleanly. All six helper/adapter
build modes preserve frozen old output exactly; eight historical cancellation
cases and 49 synthetic controls also pass. This remains source-only acceptance.

Retained-paving cancellation is committed as `f81799d`. Landscape cancellation
is also independently critic-approved; see
`CITADEL_LANDSCAPE_CANCELLATION_2026-09-02.md`. Historical phase contracts pass
194/194; real owned Source cancellation passes 10/10 with a 27.730 ms result;
the complete Site comparison passes 8/8 with unchanged geometry/furniture/profile
and only the existing timing exemptions. Total runner elapsed including artifact
comparison is 393.227095 seconds, not isolated generation time. All selected
runs shut down cleanly. Remaining source callback intervals include 2.555 s shop
preparation and 709 ms geometry-manifest work; these are not frame-time or hard
shutdown guarantees. Critic approved proceeding to native terrain admission
with those limits recorded. No ordinary runtime spawning or headed approval yet.

The following checkpoint-1 narrative records its historical boundary, not the
latest total working-tree scope.

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
approved a focused commit, not world integration or runtime readiness. That
checkpoint was committed as `af1bec6`. The world-placement product choice is now
resolved above; terrain and publication work remain to be completed.

## Checkpoint 2A: candidate field and generated-base survey (critic-approved)

Starting at clean `af1bec6`, with the explicit NPC baseline exception unchanged.
This is a source-only subdivision of checkpoint 2, not normal-world activation.

- `CitadelSiteField` derives candidates and independent recipe seeds without
  mutable RNG. Bounded jitter and disjoint region-interior reservations prevent
  citadel/citadel envelope overlap independently of query order. Oversized or
  boundary-crossing envelopes reject; no clipping, relocation or recipe edits.
- `CitadelSiteSurvey` creates its own ordinary `VoxelWorldGenerationContext`
  and `WorldGenerationSystem` from the seed and a canonical copied town-override
  snapshot. It never reads a live scene while advancing. The source intentionally
  excludes player edits: durable edits must not relocate deterministic sites.
- Every rectangle column checks the existing town/apron query and production
  surface-biome query. All land labels are allowed except town ownership;
  ocean, cave and underground identifiers are rejected. An explicit underground
  placement context is rejected before scanning. This does not prove that no
  underground cavity exists beneath a land surface.
- Surveys inspect at most 64 columns per call, with a default 2500-microsecond
  requested budget clamped to 4000, and at most 262144 columns total. Timings and
  overruns are measured, not disguised as a hard real-time guarantee. Private
  generator creation and total large-envelope latency still require profiling
  before runtime use.
- Survey coordinates are conservatively limited to +/-1,000,000 cells, leaving
  room for production town/apron lookups without integer wrap. Candidate field
  arithmetic independently supports the int32 cell domain. Unsupported survey
  coordinates reject explicitly, rather than wrapping into another region.
- Source identity binds generated-base policy version, engine, seed and canonical
  overrides. Request identity additionally binds survey policy, candidate,
  rectangle and surface context. Source identity alone is never a result-cache
  key. Snapshot timing explicitly excludes return-copy overhead; contracts
  measure whole calls separately. Neither timing is a live frame guarantee.

`surveyed` means only complete generated-base surface-policy/elevation coverage
of the supplied rectangle. `publicationReady` is always false. Input envelopes
are explicitly **caller-supplied/unverified**, not yet bound to actual recipe
geometry. Other standalone-structure conflicts and durable-edit compatibility
remain explicitly unresolved. The next subdivision must derive complete bounds,
grounding/clearance and apron provenance from prepared source artifacts, resolve
those other conflicts, and feed authoritative terrain before world activation.

No existing terrain, recipe, tree, town, NPC, navigation, save, or runtime
publication code is changed by 2A. No headed launch is authorized for this
source-only boundary. Source contracts pass; the independent critic approved
this narrowly scoped source-only checkpoint and its focused commit. This is
not full checkpoint 2 acceptance or approval for a headed launch.

### 2A source evidence

Command (from this worktree; choose a fresh directory for repeats):

```powershell
./tools/run-citadel-site-selection-contract.ps1 -OutputDirectory "$PWD/artifacts/citadel-runtime-integration/site-contract-01"
```

The wrapper records the random seed and source SHA256 hashes in `launch.json`
before launch. `report.json` contains checks, sample measurements and limitations;
`stdout.log` records stages; `stderr.log` and `watchdog.json` record engine and
owned-process exit evidence. No screenshots are required or claimed for these
source contracts. Engine: Godot 4.6.1, official `14d19694e`.

- **120/120 checks**, 0.716140 seconds, no failures, complete report. Fixed seed
  `atlas-1492`; fresh seed `atlas-site-531a91f9bc0145f899a083f271708d8e`;
  third density seed is the fresh seed plus `:density-secondary`.
- 10,000 regions per seed: 3,475 / 3,523 / 3,493 raw candidates. Reverse-order
  and fresh-instance replay, global-RNG isolation, negative seams, overflow
  rejection and guarded envelope boundaries are covered.
- Actual production WGS surveys match a separate every-column oracle for small
  64/128-column rectangles. Different slice budgets, repeated cold instances,
  input mutation, completed/partial/rejected reuse, request/source identities,
  supported-coordinate bounds and real town-apron rejection are covered.
- Whole-call maximum `begin`: **4.317 ms**; whole-call maximum `advance`:
  **4.326 ms**; reported scan-loop maximum **4.319 ms**; single-column maximum
  **0.821 ms**. Soft requested budgets can overrun by the last column and are
  reported honestly. These figures do **not** pass a strict 4 ms runtime ceiling.
  Large-envelope throughput, memory, disposal cost and gameplay frame timing
  remain unverified. The 262,144-column ceiling was tested for admission only,
  not fully scanned.
- Empty stderr, no stdout engine errors, natural exit 0, clean watchdog with
  zero owned members; global Godot process count zero after execution. Both
  module and contract parse checks also exited cleanly.

Biome exclusion predicates cover the enumerated surface-land and excluded
labels (the predicate list does not explicitly test `alpine`). The executed
world surveys are not proof of a rendered
citadel in every biome, nor a physical ocean/coast/cave acceptance run. No warm
runtime-cache or main-context/worker equivalence acceptance is claimed. Full
recipe-envelope provenance, other structure conflicts, saved edits, terrain
publication and live traversal remain for subsequent checkpoints. Existing NPC
failures remain deferred by explicit user choice, not repaired or relabeled.
