# Visible-World Readiness Baseline

**Recorded:** 2026-10-01  
**Branch / revision:** `master` / `3d957f2465aa66c773ff47c10ddeed6fd49cbcdc`  
**Worktree:** `voxel-biome-world-godot-master`  
**Related plan:** `C:/Users/arkam/Documents/voxel-godot-docs/migrations/world-streaming/visible-world-readiness-plan.md`

## Existing NPC gameplay failure

Before visible-world implementation, the required unchanged-baseline NPC run
was started with:

```text
node tools/npc/run-all-npc-tests.mjs -TimeMode Both
```

The aggregate reached the live final-rescue return scenario on seed
`atlas-1492` and recorded `final_rescue_return_actor_stalled` for Niko. The
snapshot records `routeStatus=pending`,
`routeReason=validation_step_budget_deferred`, `routeForceReplan=true`, and no
route cells. The route authority was still in `pending_budget` after 673
pending-budget frames; this is a gameplay failure in the unchanged baseline,
not a failure introduced by visible-world changes.

Evidence:

- Test report: `artifacts/npc/reports/real_tutorial_final_rescue-both.json`
- Owned-process cleanup record:
  `artifacts/node-tools/process-runs/godot-2FkbjN/watchdog.json`
- The child Godot command used `--time-mode Both --final-rescue --god-mode
  --seed atlas-1492`.

The aggregate was stopped when this first live regression was observed, so the
full `run-all-npc-tests` suite did not complete. The failing child exited with
code 1; its watchdog reports successful cleanup and authoritative zero job
members. Earlier in the same baseline session, the startup-readiness contract
passed 75 checks, the tree-publication contract passed, and the headed go-home
playtest completed its door/interior sequence. Those results do not negate the
final-rescue failure or constitute visible-world acceptance.

This issue is recorded as a pre-existing gameplay limitation for the
visible-world work. Per the user's direction, continue the visible-world plan
without changing protected NPC pathfinding code; report any later NPC result
against this baseline and do not claim this task repaired the failure.

## Visual-readiness implementation findings

The configured terrain viewer range is 96 world meters, while terrain cells
are 1.35 meters. The terrain viewer's `view_distance` is already expressed in
world units; it must not be multiplied by cell scale. `MainCore` waits for
terrain view expansion and then foreground physical/navigation readiness, but
neither establishes complete visual coverage across that view.

The current chunk prop scanner consumes seeded RNG and constructs gameplay
bodies in the same operation. Generated trees begin their separate visual
queue only after the body exists, and `TreePublicationQueue` marks a tree
published only after its visual is committed. Structures explicitly report
physical-only readiness. No production publisher currently exposes a complete
expected-versus-represented visual manifest for terrain, structures,
trees/foliage, props, and wildlife. Consequently, the new readiness owner is
not wired into startup or traversal yet; doing so before the publishers can
describe their complete source state would either stall startup or falsely
report empty coverage.

The `VisibleWorldReadiness` and production chunk-prop adapter contract was
exercised with the owned headless Godot runner and now passes 71 synthetic
checks, including the native terrain visual manifest contract:

```text
node tools/run-visible-world-readiness-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/visible-world-readiness-chunk-adapter-final
```

Report: `artifacts/citadel-runtime-integration/visible-world-readiness-chunk-adapter-final/report.json`.
It covers request/source/view revisions, complete source enumeration, circular
view coverage, in-view candidates and tiers, installed owner receipts, stale
owner invalidation, publisher-owned receipt revalidation, candidate accounting,
and native terrain mesh-block enumeration/receipts/empty completion. It does not
prove live visual coverage or startup readiness.

Terrain publication uses native `VoxelTerrain` mesh blocks at 1.35 world meters
per terrain cell. Its existing regional readiness method verifies published
gameplay collision chunks, which is not the same as exact visible mesh coverage.
A production terrain adapter now incrementally enumerates native 16-cell mesh
blocks intersecting the configured 3D view sphere, waits for `is_area_meshed`,
and revalidates live terrain owner, block revision, geometry publication, and
edited-section completion through the terrain runtime. Empty blocks receive an
explicit completion only after meshing is confirmed. Per-block revision state
is limited to live published blocks and backed by a monotonic publication
serial. This adapter is contract-tested and its terrain-specific check is now
part of normal startup after final viewer-distance expansion. It is not yet
joined to coordinator readiness or to the other visual publisher integrations.

Latest verification:

```text
node tools/run-visible-world-readiness-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/visible-world-readiness-terrain-manifest-final
node tools/run-project-compile-smoke.mjs
```

The contract report is
`artifacts/citadel-runtime-integration/visible-world-readiness-terrain-manifest-final/report.json`
(71 checks passed at that point; synthetic owner receipt contract). A follow-up
contract after replacing concatenated chunk-prop candidate revisions with
length-delimited SHA-256 receipts passed 72 checks at
`artifacts/citadel-runtime-integration/visible-world-readiness-bounded-prop-revision/report.json`.
It includes a 131-candidate chunk proving repeatable fixed-length revisions.
Compile smoke passed with
both main menu and gameplay scenes loaded. Neither result is live visual
acceptance.

Tree candidate revisions now also bind committed tree visual state, production
LOD tier and recipe signature. Near receipts require live `near` LOD; horizon
receipts accept committed `near`, `mid`, `far`, or `impostor` LOD. Readiness
rechecks the tree owner's current LOD on every query, so a demotion invalidates
near coverage immediately. The focused contract passed 76 checks at
`artifacts/citadel-runtime-integration/visible-world-readiness-tree-lod-receipts-final/report.json`,
including near-to-far invalidation and far-to-horizon acceptance. Project
compile smoke and the 75-check startup loading readiness contract also passed
after this change. This is still synthetic receipt coverage, not live visual
acceptance.

The production startup path now calls the native terrain mesh-coverage check
after final view-distance expansion and before returning terrain readiness. It
uses the live viewer distance (96 world metres), converts to cells once, and
collects current mesh receipts incrementally while the loading overlay remains
active. The startup loading readiness contract runner statically verifies this
ordering and passed 75 checks:

```text
node tools/run-startup-loading-readiness-contract-tests.mjs
node tools/run-project-compile-smoke.mjs
```

Compile smoke also passed after the startup wiring. A headed playtest was
attempted with seed `atlas-1492` using:

```text
node tools/run-playtest.mjs --visible --timeout-seconds 600 --report-path artifacts/citadel-runtime-integration/visible-world-readiness-headed/report.json --progress-path artifacts/citadel-runtime-integration/visible-world-readiness-headed/progress.txt --screenshot-path artifacts/citadel-runtime-integration/visible-world-readiness-headed/final.png
```

It did not reach the new mesh-coverage step: the last screenshot still showed
the earlier `Drawing nearby terrain` stage, and the playtest's 240-second
startup observer timed out with an empty `startup_loading_failure_result`.
Runner cleanup was authoritative and reported zero job members at
`artifacts/node-tools/process-runs/godot-Jm9lw3/watchdog.json`. The report and
screenshot are under `artifacts/citadel-runtime-integration/visible-world-readiness-headed/`.
This run is inconclusive for the new gate and does not establish live visual
acceptance. The broader visual owner (structures, trees/foliage, props and
wildlife), coordinator visual domain, traversal coverage and full headed
acceptance remain incomplete. The active implementation also remains
uncommitted in the worktree.

The existing chunk-prop state machine now stamps a completion marker only after
its seeded surface, detail, and underground phases finish. The read-only
`visible_chunk_prop_manifest()` snapshot consumes the completed chunk's stable
`prop_id` nodes and real renderable descendants; it does not generate or reorder
RNG decisions. The companion submitter registers per-kind chunk sources and
receipts into `VisibleWorldReadiness`, leaving queued trees pending until the
tree publication queue commits a renderable tree root. Project compile smoke
passed after this wiring (`node tools/run-project-compile-smoke.mjs`): both main
menu and gameplay scenes loaded. This does not yet connect terrain, structure,
or full-view ecology publishers, nor does it gate startup/traversal.

The prop submitter now clips candidate accounting to the active circular view,
so candidates in a scanned chunk but outside the requested view do not become
false blockers. Completed chunk-prop scans publish receipts into the retained
startup view ledger through a nearest-first, one-chunk-per-loading-frame scan.
The cursor revisits chunks, so scans completed before the ledger began and tree
visuals committed after their candidate scan can both be observed. This is a
startup-scoped publisher only: the view ledger is not refreshed during
traversal, and these prop receipts are not yet part of the startup completion
gate or a continuous traversal coordinator.

Latest focused verification passed 77 synthetic checks, including the
out-of-view chunk-edge case, at
`artifacts/citadel-runtime-integration/visible-world-readiness-prop-view-filter-rerun/report.json`.
`node tools/run-project-compile-smoke.mjs` passed with both menu and gameplay
scenes loaded. `node tools/run-startup-loading-readiness-contract-tests.mjs`
also exited successfully. These establish source/contract compatibility and
static startup ordering only; headed visual coverage remains unverified.

The candidate source hash now includes each candidate's XZ position because
position determines view membership and near-versus-horizon tier. The focused
contract passed 78 checks, including a same-ID candidate move advancing the
source revision, at
`artifacts/citadel-runtime-integration/visible-world-readiness-prop-position-revision/report.json`.
After adding the bounded startup chunk-discovery cursor, the startup loading
contract passed 75 checks with no failures at
`artifacts/node-tools/run-startup-loading-readiness-contract-tests.json`, and
compile smoke loaded both production scenes. Neither test is live view
completeness evidence.

## Native terrain mesh coverage follow-up

The first headed startup integration exposed a real edge-of-view deadlock:
the native terrain viewer published 457 mesh blocks, then the manifest waited
on block `(16, 5, -1)` indefinitely. Bounded diagnostics showed that no terrain
edits were pending, but the block area had no native mesh and no publication
receipt. Its center lay outside the 96-cell viewer range even though a closest-
point-to-block test admitted the corner block because its edge touched the
range. The manifest now uses the native viewer's whole-block center distance
when admitting obligations. A follow-up headed playtest passed all 25 checks
and proceeded through the tutorial return step; report and screenshot are at
`artifacts/citadel-runtime-integration/visible-world-readiness-block-center-headed/`.
The owned process watchdog `artifacts/node-tools/process-runs/godot-FLwvf7/watchdog.json`
for the preceding failure proved cleanup and zero remaining members. The
earlier expanded-radius attempt was reverted after diagnostics confirmed that
the viewer range is already expressed in cells. The visible-world contract
passed 82 checks, startup loading contract passed, and project compile smoke
loaded both production scenes. This records baseline defect handling only;
the previously reported Niko route limitation was not changed.

## Coordinator visual-domain integration (in progress)

`WorldStreamingCoordinator.region_readiness()` now has an explicit visual
domain supplied by the live `MainCore` visual ledger. The ledger can answer an
exact contained subregion by checking the row-wise union of complete source
rectangles for all five content kinds and revalidating every candidate receipt
in that subregion. An uncovered kind/row/cell remains pending; a larger view's
source set is not required for an independent local query. Ordinary
`player_traversal_readiness()` still requires terrain only, so movement does not
wait on distant detail. Initial startup waits for physical terrain/structure
readiness, submits concrete nearby structure visual receipts, then requires the
coordinator's gameplay query. Loading telemetry includes per-kind counts,
source-coverage gaps, and last prop-scan chunk/queue depth.

The first production probe proved terrain, structures, and navigation ready,
but correctly held startup because the foreground region had no complete
tree/foliage, prop, or wildlife source rectangles. The detailed failure showed
that an incomplete chunk-prop scan with an empty source revision was
mistakenly classified as failed. It is now retryable. The bounded chunk spawn
scheduler also accepts a nearest-first demand list during startup, prioritizing
foreground-required chunks without changing a chunk's seeded RNG sequence. A
later headed run passed all 25 PlaytestRunner checks and reached tutorial
gameplay assertions. Its report is
`artifacts/citadel-runtime-integration/visible-world-prop-priority-headed/report.json`;
the owned process log also recorded an unrelated `underground_air_density_at`
nil-call during teardown, with zero remaining job members but cleanup marked
failed. Treat this as partial foreground evidence, not clean full-view
acceptance. Focused visual readiness passed 94 checks, startup contracts
passed, and compile smoke loaded both production scenes.

The full configured horizon is still not certified: terrain mesh blocks are
accounted for, but generated trees/foliage, non-tree props, and wildlife do not
yet have a low-cost far representation or complete horizon source manifest.
Next, join existing deterministic ecology/publication owners to the horizon
ledger and retain retryable near-detail promotion; unspawned guesses and
physical bodies alone cannot become visual receipts.

The regional consumer contract was updated with a distinct synthetic visual
owner and passed 133 checks at
`artifacts/citadel-runtime-integration/world-streaming-consumer-visible-world-readiness-rerun/report.json`.
The first run without that owner correctly failed checks that formerly expected
ready; this exposed the contract migration needed when visual readiness became
required. The plan's maturity loading matrix and journey were attempted, but
both stop before launching because this checkout lacks
`addons/terrain_meshing_backend/bin/terrain_meshing_backend.windows.template_release.x86_64.dll`.
The debug extension binary exists, but the matrix requires both debug and
release binaries. No result from either is claimed.

## Circular coverage and directional preparation follow-up

Subregion coverage now follows the configured circular view envelope rather
than its square XZ bounds. Each row is clipped to cell centers inside the
configured radius, and complete source rectangles must cover every remaining
cell for each content kind. The visual-readiness contract passed 95 checks,
including a circle whose square corners intentionally have no sources. Startup
loading contracts, project compile smoke, and the 133-check world-streaming
consumer contract also passed.

Startup chunk-prop discovery now ranks its bounded chunk set with the existing
`GeneratedContentViewPriority` policy. Camera-visible and predicted-corridor
chunks are scheduled before background chunks; chunk-local seeded generation
and IDs remain owned by the existing generator. This improves promotion order
but does not yet provide a complete horizon receipt or verify fast-turn visual
continuity. Full-view generated ecology and wildlife coverage, continuous
movement refresh, per-consumer relocation manifests, headed traversal captures,
and representative performance acceptance remain open.

The generated-structure visual adapter now applies the same circular view
membership test as terrain and chunk-prop candidates. Structure blocks inside
the broad-phase square but with cell centers outside the configured view are
excluded from the demand instead of being rejected as out-of-view candidates.
The focused visual-readiness runner passed 96 synthetic owner-receipt checks,
including this square-corner case, at
`artifacts/citadel-runtime-integration/visible-world-readiness-structure-circle-20261001-rerun/report.json`.
Project compile smoke loaded both the main menu and gameplay scenes. Neither
result proves live full-view coverage; the open items above remain unresolved.

Coordinator-facing visual readiness now reports a bounded visual queue depth
(pending chunk prop work plus view chunks whose source manifests have not yet
been submitted) and the player's offset from the active view-ledger center in
terrain-cell units. The ledger stores both through its bounded diagnostics and
returns them with the readiness result so traversal can expose stale-view lag.
Compile smoke loaded both production scenes, and the startup loading contract
passed 76 checks with a static audit for these diagnostic fields at
`artifacts/node-tools/run-startup-loading-readiness-contract-tests.json`.
This instrumentation makes outstanding coverage visible; it does not refresh
the ledger during movement or certify full-view coverage.

## Full-view gate probe and source split

The generated-structure visual adapter now accepts a completed regional source
description for horizon visuals independently of physical publication. It still
requires live generated block renderables and rechecks the source revision
before finishing. Its default foreground path continues to require physical
publication. The focused contract passed 98 synthetic receipt checks at
`artifacts/citadel-runtime-integration/visible-world-readiness-structure-horizon-source-20261001/report.json`.

A temporary normal-menu full-view gate was exercised in a headed playtest on
seed `atlas-1492`:

```text
node tools/run-playtest.mjs --visible --timeout-seconds 600 --report-path artifacts/citadel-runtime-integration/visible-world-full-gate-headed-20261001/report.json --progress-path artifacts/citadel-runtime-integration/visible-world-full-gate-headed-20261001/progress.txt --screenshot-path artifacts/citadel-runtime-integration/visible-world-full-gate-headed-20261001/final.png
```

The run entered that gate after nearby gameplay readiness but did not reach
first control. Its final trace at about 240 seconds showed 42 view chunk keys,
48 pending chunk-prop spawn states, and only one completed source rectangle
for each of trees/foliage, props and wildlife. The source state cannot finish
until the shared chunk generator completes its expensive underground scan,
although many far surface candidates are already known. The terrain ledger
also found a gap at cell `(258, -81)`: the native viewer admits 16-cell mesh
blocks by 3D block-center distance, while the ledger demanded every XZ cell
center in a flat circle. These are distinct coverage contracts; broadening the
mesh admission would wait for blocks the native viewer will not publish.

The headed report and loading screenshot are under
`artifacts/citadel-runtime-integration/visible-world-full-gate-headed-20261001/`.
The owned Godot process exited with functional code 1; watchdog
`artifacts/node-tools/process-runs/godot-PyJU1N/watchdog.json` records
successful cleanup and authoritative zero remaining members. The temporary
gate and its extra view-chunk startup demand were removed after this failed
probe, so normal gameplay is not held by an unsatisfiable full-view contract.
Next, the production chunk source must expose completed visible surface
candidates before underground completion, including batched decorative
foliage; the view envelope must follow the native mesh publication footprint.
Only then can a full-view startup gate and continuous movement ledger be
accepted honestly.
