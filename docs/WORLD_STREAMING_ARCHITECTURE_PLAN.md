# Spatial world streaming and rendering architecture

Approved implementation plan, 2026-09-10. Baseline: 2c71199. Work branch:
codex/world-streaming-architecture, in the existing citadel-visuals worktree.

## Acceptance contract

- Measure fresh world creation, cached Continue and exploration separately. The
  original 90-second cold target is provisional following the user's timing
  clarification; no replacement threshold has been chosen.
- Required area: 64m horizontal radius, expanded for structural support, crossings
  and scenario dependencies. Tutorial retains complete town/actor readiness.
- 60 FPS at 1920x1080 on the RTX 5060 Ti, including ordinary sprint traversal.
  Five-minute observations: p99 <=33ms, no recurring streaming stalls >33ms,
  no frame >100ms. Measure rendering CPU/GPU and frame cadence independently.
- Preserve near geometry, material character, terrain solidity and interaction IDs.
  Distant interiors/cosmetic detail may remain pending. Record full-site completion
  separately; do not relabel partial readiness as complete citadel readiness.
- Cold means fresh process and empty generated-artifact caches; warm runs separate.
- User explicitly authorizes terrain/structure publication changes to navigation;
  route search, movement, door execution and traffic behavior remain protected.

## Ordered cutovers

1. Extend existing observations: monotonic frame cadence, rendering CPU/GPU,
   draw/primitive counts, worker work, upload/registration and queue latency.
   Capture startup, approach, courtyard, forest, sprinting and unloading.
2. Extend BuildingPublicationPreparation/BuildingScenePublicationJob to compile
   final spatial geometry/transform/custom-data buffers on owned workers. Preserve
   full-resolution physical output and existing readiness for this first cutover.
3. Introduce regional dependency-complete readiness and composed scheduling.
4. Add source-derived building LOD, conservative wall occluders and shared tree
   batching through the existing production tree grammar/detail system.
5. Profile remaining generation costs; move dominating pure geometry/voxel work
   into the existing native extension. Terrain LOD is a separate verified cutover,
   never an unmeasured simplification/backend toggle.

## Contracts

Render packets bind seed, source revision, durable edits, recipe/material version,
spatial cell and detail tier. Initial grid: 32 terrain cells / 43.2m, XZ. Keep native
terrain blocks and navigation tiles on their own grids with explicit intersections.
Stable part owners and cross-cell references prevent duplicate collision/interaction
objects. Group by spatial cell/material/geometry family; preserve instance data and
part ownership. Main thread uploads/attaches bounded segments; keep the previous
visual until its replacement is complete. Keep the 4ms cooperative budget initially;
split oversized atomic operations before increasing throughput. Preserve one-shot
consumption, stale rejection, weak ownership, cancellation and worker retirement.

The composed coordinator prioritizes existing owners; it is not a geometry or
readiness authority. Interfaces: request_region(bounds, priority, reason),
region_readiness(bounds) -> ready/pending/failed with dependencies and revisions,
release_region(request_id). Retain retryable demand under backpressure.

Regional readiness requires validated source and terrain changes, prepared visuals,
collision and interaction artifacts, safe publication outside occupied geometry,
then revision-matched navigation acknowledgement for all necessary crossings. Audit
terrain/door/stair/porch/seam ownership before changing publication. Do not revive
the rejected native navigation-bake replacement. Cosmetic expansion may not discover
new physical obligations. Preserve determinism across staging and cancellation.

Priority: safety/edits, required scenario/interactions, predicted traversal, visible
detail, background refinement. Predict ten seconds ahead from movement/facing;
retain a surrounding ring for reversals, an extra region ring and ten-second unload
hysteresis. Bound queues/memory without dropping demanded work. Surface loading
feedback rather than expose unsafe territory; acceptance traversal must not stall.

Visual distances from camera to bounds: near 0-96m full quality, middle 96-192m
simpler decoration/reduced small shadows, far 192-384m source-derived silhouettes
and coarse terrain/vegetation. Retire unneeded visuals beyond that while preserving
demanded gameplay. Keep apertures, landings and collision readable at transitions.
Occluders derive conservatively from opaque geometry and exclude movable doors.

## Verification and delivery

Batch fixes/checks around cutovers, using existing Node/owned-watchdog runners and
early headed inspections. Preserve baseline artifacts. Every launch proves zero
owned members. Tests cover deterministic near-output parity; lifecycle/cancellation,
stale packets, edits during compilation, reversals, unloading and shutdown; real
gate/door/stair/region movement and NPC navigation acknowledgement; real menu New
Game/Continue, save/reload/dig/build/harvest; day/night and LOD/occlusion visuals.

Final load samples: three cold known-citadel-seed runs plus one each of two fresh
seeds, reporting each against the provisional 90s target. Run broad playtest and affected navigation/lifecycle suites at
each production cutover. Baseline failures stay explicitly attributed; regressions
block promotion. Teleports are diagnostic setup, not continuous-travel acceptance.
Commit verified milestones, remove superseded production paths after cutover,
retain one world authority, preserve save format v2 and durable deltas.

## Progress

- Baseline committed and branch created.
- Phase 1 measurement milestone verified: composed opt-in render/cadence observer,
  explicit 1080p runner options, actual stretched-window size verification, and
  corrected ordinary-menu fixture input/cleanup. Baseline evidence and limits:
  `WORLD_STREAMING_MEASUREMENTS_2026-09-10.md`. Full citadel readiness remains
  152.814s in the teleport diagnostic; measured ordinary traversal fails the new pacing contract. Five-minute
  coverage, unloading and final cold-cache acceptance remain outstanding.
- First phase-2 portion implemented: worker-prepared immutable masonry segments
  and one-buffer static batch uploads, preserving completed-part boundaries,
  geometry/collision/material order and lifecycle. Exact headed source/count
  parity passed; total publication time did not materially improve.
- Initial-location diagnostic now selects the player position before attachment
  and terrain streaming, with zero subsequent teleports. Known candidate sample:
  83.373s current startup readiness, 134.274s full scene-ready. This is not the
  new 64m readiness contract or flag-free menu acceptance. Evidence, limits and
  attributed broad/NPC failures: WORLD_STREAMING_PACKETS_AND_INITIAL_SPAWN_2026-09-10.md.
- Spatial owner/cell grouping was implemented and measured at matching cameras,
  but not promoted: extra submissions did not consistently pay for their culling
  benefit. Production grouping remains f780e2c. Preserve the complete experiment
  and comparison in WORLD_STREAMING_SPATIAL_GROUPING_EXPERIMENT_2026-09-10.md.
  The existing headed runner now records settled overview/courtyard/door phases.
- Worker-owned masonry records now carry write revisions and deeply frozen
  recipes. Authoring inputs remain mutable. In the production diagnostic,
  prepared lookup fell from 637ms to 15ms and total publication CPU from 12.79s
  to 11.74s with exact source/instance/collider parity. Current startup was
  82.543s; scene-ready capture was 127.030s. This is one sample, not the 64m/90s
  contract, and publication still exceeds the 4ms cooperative budget. Evidence
  and regression outcomes: WORLD_STREAMING_OWNED_RECORDS_2026-09-10.md.
- Paving and roof geometry/final buffers now prepare on the existing worker.
  Shared paving batches retain all instances/colliders and reduce MultiMeshes
  from 1548 to 1477. Headed initial-spawn sample: 80.048s current startup,
  122.318s scene-ready; neither proves regional gameplay readiness. Broad replay
  161/163 with recorded asset/headless-capture failures. See
  WORLD_STREAMING_SURFACE_WORKERS_2026-09-10.md for commands, costs and limitations.
- The user's New Game/Continue timing distinction makes the cold 90s target
  provisional; measure cold creation, cached Continue and exploration separately.
  No replacement threshold has been chosen. Preserve the playable-radius and
  traversal requirements regardless of startup target.
- Exact navigation installation receipts now bind source revisions to emitted
  surfaces and installed owner resources. Staged startup consumes them for its
  existing NPC tile set. This is not 64m regional readiness or crossing/movement
  acceptance. Service lifecycle 33 checks, startup 9 checks and nav-world 84 cases
  pass; broad replay remains 161/163 with the same recorded baseline failures
  and forced cleanup. Real menu New Game took 33.227s; the 75-second traversal still failed
  pacing (post-draw p99 51.1ms). See WORLD_STREAMING_NAVIGATION_RECEIPTS_2026-09-10.md.
- Next: retained regional dependency closure, initially keeping whole required
  structures gated, then partial structure checkpoints. Address measured
  publication validation costs and submission fragmentation before reintroducing
  spatial subdivision.
  The earlier spatial experiment report contains its owner inventory and broad reference replay. The spatial
  candidate additionally stopped on an engine RID error that did not recur in
  the reference replay; that failure remains unresolved and blocks its reuse.
  Keep the cooperative budget and use initial-location startup measurements.
- Runtime navigation compilation now uses the existing owned worker lifecycle,
  retaining old regions during bounded polygon upload and rejecting stale/other-
  seed installations. The existing lifecycle fixture passes 111 checks and the
  nav-world suite passes 86. The headed candidate exercises worker preparation
  for all 42 tiles with current installation receipts. Captured source comparisons
  exposed infinite live prop bounds; finite collider-derived bounds restore all
  1,752 proved false vertical rejections. Evidence and regression results belong in
  WORLD_STREAMING_NAVIGATION_PUBLICATION_2026-09-11.md. This is an installation
  cutover, not completed regional traversal readiness.
- Regional composition is now an unpromoted candidate on top of `ea691ed`.
  Structure obligations feed retained terrain/navigation demand; initial loading
  and motion consume current owner acknowledgements. Full physical site
  publication remains required while local dependency queries avoid expanding
  to an entire generation reservation. See the candidate report below. Normal
  menu/Continue, broad regression and uninterrupted traversal still need to pass
  before this cutover is promoted. Partial physical checkpoints remain unfinished.
  A scene-ready citadel still reports gameplayReady=false independently.

## Regional composition candidate — 2026-09-11

Uncommitted implementation and diagnostic evidence, not acceptance. Two subagents
implemented separate structure/navigation providers; parent integrated the
coordinator, startup, motion and existing runners. A separate read-only subagent
is investigating the measured navigation snapshot stall.

- Existing startup contracts: 34/34 in
  `artifacts/citadel-runtime-integration/regional-composed-startup-08.json`.
  Command: `node tools/run-startup-loading-readiness-contract-tests.mjs -ReportPath artifacts/citadel-runtime-integration/regional-composed-startup-08.json -TimeoutSeconds 120`.
  Synthetic owners test closure, admission retries, revisions, overlapping demand,
  hysteresis, reset and locally scoped queries. No live gameplay claim.
- Native terrain/motor fixture: 65/65 in
  `artifacts/citadel-runtime-integration/native-admission-regional-composed-03/report.json`.
  Command: `node tools/run-citadel-native-admission-contract.mjs -OutputDirectory artifacts/citadel-runtime-integration/native-admission-regional-composed-03`.
  Actual native collision and Player motor with synthetic regional receipts.
- Navigation-world regression: 86/86 in
  `artifacts/citadel-runtime-integration/regional-composed-nav-world-01/report.json`,
  Both modes. Run before the latest local-query refinements; no route-stack edits.
- Headed initial-location runs use seed `atlas-3376622889`, region `-2,-2`,
  spawn `-3334,-2666`, 1920x1080, SkipTutorial/ForceDaytime/ForceClearWeather,
  CaptureNavigationRejections, startup deadline180s and total deadline600s.
  Command prefix: `node tools/run-citadel-candidate-teleport-playtest.mjs`.
  Complete exact arguments and source hashes are in each run's `launch.json`.

Recorded headed failures under `artifacts/citadel-runtime-integration`:

1. `candidate-teleport-regional-composed-01`: startup timeout180s. Terrain
   displayed89.24s; complete scene eventually published, regional gate pending.
   Failed capture inspected: terrain, trees and distant citadel visible, no
   gameplay or close visual acceptance. Initial report lacked regional detail;
   existing runner now preserves bounded progress and terminal owner state.
2. `candidate-teleport-regional-composed-02`: startup timeout180s. Unconditional
   whole-reservation dependency expansion demanded299x345 terrain cells, over400
   navigation tiles and126 still-missing terrain chunks. Terrain viewers were
   also barred during loading; closure work could starve navigation. Fixes retain
   full physical publication but request actual local source dependencies, allow
   retained viewers after initial collision readiness, and reserve alternating
   frames for navigation within the existing4ms cooperative budget.
3. `candidate-teleport-regional-composed-03`: startup137.333s; scene audit and
   structural-clearance checks pass, but45s ordinary-input approach fails.
   Player moves about30m then waits. Trace proves global navigation events
   repeatedly invalidate structural closure and broad enclosing demand stalls
   local motion. Candidate fixes use structural/edit/door-owner identity and
   local dependency queries covered by retained demand. Startup success is not
   full-citadel gameplay or traversal acceptance. Measured source snapshot
   preparation reaches153.476ms, exceeding the cooperative budget.

All three failures exited naturally, clean engine logs, unchanged source hashes,
cleanupPassed=true and authoritativeZeroProven=true. Captures/verification reports
are retained in their run directories. Initial parse/type failures and the
synthetic fixture's first-frame/default-empty-rectangle mistakes are separately
recorded in the numbered focused logs; they are not generated-world defects.
4. `candidate-teleport-regional-composed-04`: startup144.703s; scene and structural
   checks pass, approach still times out. The global structural invalidations are
   removed; movement reaches roughly70m but26/44 sampled motion proofs wait for
   local navigation source/ID coverage. Terrain and physical owners remain ready.
   Clean engine/unchanged sources/natural exit/cleanup/owned-zero verified again.
   Scheduler refinement visits up to8 tiles inside the unchanged4ms slice and
   finishes captured source-ID proofs before building another queued snapshot.

5. `candidate-teleport-regional-composed-05`: startup131.029s; approach reaches
   28.737m from visual bounds but times out waiting for tiles`-210,-173` and
   `-209,-173`. Their source revisions remain unchanged across the last10s.
   All owners/collision/scene checks remain valid; interruption still blocks
   promotion. Clean engine/unchanged sources/natural exit/cleanup/owned-zero
   verified. The next candidate removes a redundant full regional obligation
   walk from publication advancement (readiness still checks it) and records
   bounded tile-work progress in the existing observer.

6. `candidate-teleport-regional-composed-06`: startup132.208s; approach still
   stops28.293m from visual bounds. Captured local source keys remain stable;
   final queue telemetry records12317 tile visits, but pending tiles have no
   retained snapshot. Close capture inspected: citadel walls and terrain visible,
   with the real `Preparing nearby world...` motion hold. This is a production
   traversal blocker. Natural exit, unchanged sources, clean engine and owned-zero
   verified. Proof processing still followed expensive shared queue work and
   could be skipped each time the slice expired. The next candidate consumes
   captured facts/receipts first and avoids redundant shared-queue admission.
   Read-only subagent inspection also confirmed that unrelated static events
   clear snapshot caches and recapture unchanged tile sources with newer global
   counters; using those counters as worker generations can cancel valid work.
   This is a confirmed code path, not yet attributed as the live failure cause.
   The ordinary-input phase also fails the frame-pacing target:665 samples,
   p99=247.1ms, max297.422ms and102 frames above100ms. Its render CPU p99=6ms
   and GPU p99=13.3ms; source snapshot construction still reaches153.955ms.
   Capture/audit overhead and this short diagnostic exclude performance
   acceptance, but the CPU publication stalls are independently visible.

7. `candidate-teleport-regional-composed-07`: startup132.749s, approach timeout
   28.886m from visual bounds. Source-ID proof now progresses to concrete
   `tile_not_registered` receipts, but a completed worker slot waits while
   unrelated shared-queue snapshots return`navigation_publication_busy`.
   Final slot`-208,-173` was ready; queued attempts were`-205,-176..-179`.
   Close screenshot inspected: visible wall/terrain and loading motion hold.
   Natural exit, unchanged sources, clean engine, cleanup and owned-zero pass.
   Next candidate finishes the existing occupied slot before other captures,
   avoids recapturing while compilation/upload is pending, retains absent
   caller demand, and preserves foreground-only admission. Failed slots report
   failure then retire so other demands can progress; same-frame calls validate
   current ownership even when no additional upload work is allowed.

8. `candidate-teleport-regional-composed-08`: startup130.075s, ordinary-input
   approach succeeds in14.858s to7.879m from visual bounds (1/15 sampled holds).
   All28 diagnostic checks pass, including42 source-tile publication receipts.
   **Overall runner fails**: Godot reports2 navigation raster edge errors.
   Natural exit0, unchanged sources, cleanup and owned-zero are verified; the
   warning is not waived. Saved-source replay`regional-edge-replay-01` reproduces
   the same2 errors through the production navigation service, without Main or
   generation. Source localization is ongoing before another full run.
   The movement phase remains outside performance acceptance:523 cadence samples,
   p99=160.4ms/max233.652ms/44 frames above100ms; render CPU p99=6.6ms and
   GPU p99=7.4ms. Snapshot build max163.875ms. Close and courtyard captures
   inspected: citadel/terrain present, but loading feedback persists and the
   stair-landing capture is too dark/occluded to prove walkability or lighting.

No verified regional milestone commit yet; navigation warning and frame pacing
remain promotion blockers. Broad and normal-menu regression are still pending
for this unpromoted candidate.

Saved-source warning localization (no production geometry/settings changes):
`regional-edge-replay-02` identifies tile`-208,-176`; isolated replay03 reproduces
the warning and maps all four conflicting edges to polygon40, source paving
segment54/cell`-13975,-11830`. Its125x162.842mm rectangle lies entirely in one
unchanged250mm engine merge bucket. This is a collapsed polygon, not an
inter-region seam mismatch. Godot4.6.1's`NavRegionBuilder3D::get_point_key` and
`_build_step_find_edge_connection_pairs` confirm the floor-quantization and
two-edge limit ([engine source](https://github.com/godotengine/godot/blob/4.6.1-stable/modules/navigation_3d/3d/nav_region_builder_3d.cpp)).
The source-comparison subagent found that this fragment is unchanged from the
prior passing run. Its two merge neighbours were removed by live copper-ore
collision, leaving the small fragment isolated. Prop`atlas-3376622889:-3314,-2804:9`
is inside the source-backed citadel reservation; natural-prop exclusion currently
consults town/ordinary structure footprint records but omits the citadel.
`candidate08-vs-finite-bounds-saved-source-analysis-20260911.json` records the
comparison. A bounded prop-admission/land-use fix is being prepared before any
navigation precision change; no warning suppression, surface deletion or raster
setting change has been made.
Saved blocker evidence is a real enabled SphereShape3D, radius1.351800m at
`(-4473.900391,42.398388,-3785.400146)`. The source paving strip is only0.953533m
wide. Its neighbours' rejection is a legitimate candidate for actor-clearance
blocking, not the previously fixed infinite-height collider bug; do not relax
collision filtering to restore them. Repair the missing natural-prop land-use
contract and re-evaluate the unchanged source geometry afterward.
The prop candidate now consults admitted reservations in the existing surface
natural-prop exclusion, including after source-cache eviction. The existing
chunk-prop state machine retains pending/failed admission before random draws or
attempt advancement; synchronous callers hand the untouched state to the same
retry queue. Underground prop generation and source-authored trees keep their
separate existing paths. `native-admission-natural-props-01/report.json` passes,
including explicitly synthetic reservation/RNG tests plus real native/motor
checks. Startup contracts`regional-composed-startup-12.json` pass37/37.
Headed candidate09 is pending with navigation geometry/filtering/settings
unchanged from08; this run tests the actual prop-land-use repair.
The latest focused startup run is `regional-composed-startup-11.json` (37/37),
including synthetic proof-before-publisher ordering, receipt replacement and
stale-capture rejection. `regional-recapture-lifecycle-02.json` passes119/119
service contracts, including real worker/upload preservation across unchanged
local-source recapture, same-installation reuse, changed-source rejection and
orphaned-owner cancellation. Its owned watchdog is`godot-Ip6Vx1`; the preceding
`regional-recapture-lifecycle-01` failed to parse a newly added fixture variable
(explicit WeakRef annotation corrected), not production geometry. Node candidate
runner checks pass15/15. None of these focused results is gameplay acceptance.
After the owned-slot change,`regional-owned-slot-lifecycle-03.json` passes127/127
(watchdog`godot-yDmTxj`, natural success/cleanup/owned-zero). Added cases use the
real worker, shared queue and service with synthetic producers; the failed-slot
case explicitly injects an upload failure. `regional-owned-slot-lifecycle-02`
was a parse failure in that new fixture, corrected without production changes.
`regional-owned-slot-nav-world-01/report.json` passes86/86 at seed`atlas-1492`
in Both mode, before the final failed-slot/same-frame guard refinements.
The separate read-only profile analysis confirms that the final third-run source
snapshot maximum is154.016ms (the earlier153.476ms was an intermediate sample).
Tile publication max0.378ms and map synchronization max0.728ms are much smaller.
`GeneratedWorldNavigationAdapter.build_navmesh_tile_snapshot` still copies global
cell maps, rebuilds full collision indexes, samples256 terrain cells, and filters
building surfaces before worker capture. Individual substage dominance has not
been measured; cache-eviction dominance is also unproven. The next performance
boundary is bounded source capture plus pure index/clearance work on the existing
publication worker, preserving live source ownership and exact filtering.

9. `candidate-teleport-regional-composed-09`: all28 diagnostic checks pass;
   startup132.195s, ordinary-input approach12.14s. Empty stderr, unchanged source
   files, natural exit0, cleanup and owned-zero verified. Courtyard, home door and
   keep stair-exit captures inspected: geometry present, home threshold visibly
   clear, but dark close views and persistent loading feedback limit the visual
   claim. These diagnostic cameras do not prove traversal of the stairs/interior.
   Saved-source comparison confirms the offending copper ore is absent from all
   42 blocker inventories; both paving54 neighbours return and the unchanged
   merger reconstructs their648.438x162.842mm strip. Accepted construction source
   is byte-identical to08;7539 building surface records restored, none removed or
   modified, door/crossing records unchanged. See
   `candidate09-vs08-paving54-source-evidence-20260911.json` for supporting saved
   source analysis (not a live mesh readback). Performance still fails:430
   post-draw intervals, median16.8ms/p95=135.5ms/max191.823ms,38 above100ms.

The subsequent real-menu New Game check blocks promotion:
`artifacts/npc/node-production-runs/save-continue-c4deyj`, seed`atlas-37740664`,
returns to the menu with`initial_region_dependency_failed` after21.983s. Its
fixture mistakenly accepts inactive loading as successful loading, then reports
`player_could_not_reach_starter_door_by_input`. The menu screenshot independently
confirms the actual startup failure. Continue never ran. Watchdog`godot-7Zc9VO`
records natural exit1, clean engine and owned-zero. Dependency diagnosis and
correction of misleading fixture failure reporting are pending. The simultaneous
broad run`regional-composed-broad-01`, seed`atlas-2000247266`, is still active;
neither concurrent run is performance evidence.

`regional-composed-broad-01` finished naturally:154/163, clean engine and
owned-zero (`godot-4EfWt7`). Failed checks: tutorial startup, escape-menu New Game,
generated environment prop visuals, character assets, mining tool requirements,
first-strike hardness, break-progress reset, right-mouse interaction and held-item
strike input. In-game New Game reported loading incomplete; subsequent interaction
failures cannot be promoted as baseline noise. The prior committed run had five
failures with different coverage/seed, so no same-seed baseline attribution is
claimed here. Reload was slow but completed; no prop retry infinite loop found.

The next batch repairs source-proven double-door publication incompatibilities:
ordinary door leaves share a routing portal/link ID, while the regional receipt
path previously discarded that duplicate ID and later rejected the legitimate
leaf records as ambiguous. Door receipts now accept exact source requests
`{id,portalId,cell,start,end}`, retain/check each installed RID, and still reject
identical source duplicates. Requirements use every actual portal leaf, including
leaves across navigation tiles, rather than the smart registration's last leaf.
Existing link IDs, installed geometry and door execution are preserved. The
normal-menu fixture now requires the actual startup completion signal and saves
the complete startup failure instead of interpreting inactive loading as success.
These are verified code defects; the first failed live snapshot lacked nested
failure details, so which fired first remains unproven pending the next run.

Focused results: `regional-double-leaf-lifecycle-01.json`134/134 with real worker,
upload/server and synthetic source data (`godot-o8R8sp`);
`regional-double-leaf-startup-02.json`43/43 including synthetic grouped leaves,
seams and mismatched sources; `regional-double-leaf-door-01/report.json`48/48 in
Both mode. The first startup attempt failed to parse a new fixture's inferred
boolean; explicit annotation fixed it, with no production change. No gameplay
acceptance is claimed from these contracts. Real-menu run`save-continue-CBSW8h`
is active on the integrated batch.

`save-continue-CBSW8h` subsequently passes both real-menu stages at fresh seed
`atlas-30593245`. Startup completion signals are observed, the player reaches and
opens the starter door through input, acknowledges dialogue and saves. Continue
restores the generic home order. Trace: Mira approaches her closed home door,
opens it at38.067s before entering its cell at38.4s, reaches strict interior with
the door still open, then the final observation/capture shows the closed door
after clearance. Final observer image inspected. This proves the existing
tutorial save/Continue scenario, not citadel interior traversal or performance.
Watchdogs`godot-uQeXcs`/`godot-KgI228` confirm natural0, clean engine and owned-zero.
The current nav-world suite also passes86/86 in Both mode:
`regional-double-leaf-nav-world-01/report.json`.

Same-seed attribution is now running in detached reference worktree
`../voxel-biome-world-godot-regional-baseline-20260911` at exact`ea691ed`, with
the same two native debug dependencies copied and a fresh owned editor import.
No gameplay source changes were made there. Initial baseline broad evidence at
`artifacts/citadel-runtime-integration/regional-baseline-broad-01/report.json`
already reproduces the exact20 perimeter lamps/25 total torches on
`atlas-2000247266`. The full baseline and updated candidate broad runs are pending.
The read-only placement audit identifies the existing per-cell fence versus
town-level lamp elevation conflict as a possible cause, not yet a proved
per-cell attribution. Do not lower the lamp threshold.

Another cutover risk is now explicit: direct `Main.tscn` fixtures still use the
old non-deferred `_ready` path by default, which never initializes regional
demand. The new motion gate always requires that demand. Main-menu and citadel
diagnostic runs select deferred boot and are covered; direct-scene movement
must be brought through the same readiness lifecycle before full promotion.
The broad runner's initial scene also takes that old path; its later New Game
test activates the staged path. Do not cite the initial broad fixture as proof
of regional startup or bypass the movement gate to accommodate it.

The same-seed comparison is complete: both `regional-double-leaf-broad-01` and
the detached `ea691ed` baseline finish 158/163. The same five failures remain:
20 perimeter lamps, pending procedural-tree visual/authority/shadow expectations,
and character asset pack expectations. Their recorded details match apart from
small shelter/light measurements. No new failed broad assertion on that batch.
Baseline watchdog `godot-S0cM2k` records natural exit1, empty stderr, successful
cleanup and authoritative owned-process zero. The candidate final screenshot was
inspected: forest terrain/trees and dialogue are present; this is not a citadel
or performance capture. These failures remain defects, not waived acceptance.

The next coordinated cutover removes the old ordinary `_ready` bootstrap and
synchronous New Game reset. All Main entries use the staged lifecycle. Direct
launches get the existing opaque HUD loading presentation through a lightweight
composed overlay before world setup. The read-only startup waiter checks actual
current domains and failure state for both initial loading and reload; explicit
diagnostic setup stays excluded from gameplay and leaves physics disabled.
The direct fixture inventory is migrated together, preserving assertions and
separating diagnostic setup from ordinary readiness. Interactive underground
destination selection now precedes initial demand capture. Shutdown waits for
the active startup/reset coroutine before retiring its owners, and pending
readiness loops observe cancellation. Compile smoke passes in
`direct-startup-compile-01.json`; headed citadel run10 is in progress. This batch
is not yet promoted or performance-accepted.

Direct-startup verification update (2026-09-11):

- Citadel run `candidate-teleport-regional-composed-10` completed 28/28 scene
  checks, startup 132.614s, and a normal-input approach with no terrain holds.
  Its wrapper correctly rejected the run because eleven fixture scripts changed
  while it ran. Repeat with frozen sources; do not waive this verification.
  Inspected spawn, courtyard, home-door, stair-exit and furniture captures.
  The gatehouse stair-landing camera clips geometry and cannot prove that view.
  Approach cadence still fails: p99 157.6ms, max 178.588ms, 37 frames over100ms.
  CPU/GPU rendering maxima were 5.859/7.621ms; main-thread navigation snapshot
  construction reached 179.014ms. This remains a production performance blocker.
- Startup contracts `direct-startup-contract-03.json` pass51/51. An earlier
  synthetic Main lacked `shutdown_requested`; null-safe cancellation checks
  corrected that fixture-facing error without changing the readiness standard.
  Real-scene cancellation during tutorial publication now exits without a
  completion signal or enabled player physics, with zero pending voxel tasks
  (`godot-8INQHn`). Audio playback is stopped before owner teardown.
- Broad `direct-startup-broad-01` stopped on a real detached-tree transform
  error (`godot-Zl0qMY`); its forced shutdown reached owned-process zero but
  was not a clean test completion. Tree publication now retains detached work
  while excluding detached/retiring bodies and viewers from world-transform
  queries. Prepared-tree contracts pass55/55 in
  `prepared-tree-publication-direct-startup-01/report.json`; queue contracts
  pass18/18 in `artifacts/node-tools/process-runs/godot-tPTRab/stdout.log`.
  Both process receipts are clean.
- The broad shelter failure exposed test contamination: scenario-only restore
  recreated actors at their spawn positions after the earlier real home-arrival
  check; baseline extra townspeople masked this with a global shelter count.
  The fixture now restores NPC physical facts through the existing save API,
  checks the actual three required nonfighters, and preserves the1800-frame
  deadline. This is fixture setup, not a routing change or gameplay acceptance.
- Terrain publication run03 passes all checks with clean receipt `godot-k33ayo`.
  A fresh remote chunk needs retained regional demand in this fixture now that
  player terrain is already ready at startup. Earlier run02 also found a0.5m
  analytic/collision discrepancy at the player. Its actual seed differs from
  run03 because ordinary tutorial startup rerolled the requested fixture seed;
  the later pass does not resolve that discrepancy. Investigation is pending.
- All45 changed GDScripts compile (`godot-SwzqT0`). Broad run02 is active.
  Independent review identified two additional cancellation risks to address:
  saving partial initial startup on exit, and losing window-close intent while
  a failed world is retired before retry. No milestone promotion yet.

The two exit defects are corrected. Real initial cancellation with an explicit
synthetic save sink records zero snapshot writes, no completion signal and
disabled physics (`godot-A2K73W`). A synthetic failed-owner retirement through
the real menu retains window-close intent, drains both owners and creates no
replacement (`godot-E0UFr5`). Both receipts are clean; neither is gameplay proof.

Broad02 finishes157/163 with a clean engine and owned-zero (`godot-SgBnbW`).
The tutorial NPC cohort check now passes. The five attributed baseline failures
remain, plus `mining_tool_requirements` (iron blocked=false/mined=true), which is
under investigation. The save round trip eventually passed, but spent several
minutes in synchronous `reload_chunks` before continuing. This identifies an
unmigrated runtime/F9 load path; staged runtime-load work is pending. The final
forest/dialogue screenshot was inspected. This run is not performance evidence;
small lifecycle checks ran concurrently, and the late exit-only corrections were
not loaded by this already-running process.

The terrain-height mismatch is now separated from physical publication:
structure reservations intentionally do not modify the placement projection.
The fixture's old expected14.1m was that placement reference; native density
includes the floor cap and reserved air whose zero crossing is13.6m. Changing
the placement projection would risk generation feedback. The diagnostic now
queries accepted mesh edits or generated lattice density, keeps the placement
reference visible, and retains the0.108m threshold with unrounded collision.
Run04 at the actual failing seed `atlas-75590047` passes11/11: expected13.6m,
collision13.5964365m, error0.0035635m. No terrain geometry changed. The fixture
now preserves its requested seed and disables user autosaves. Raw published SDF
readback is being added to independently check the selected source samples;
this is diagnostic evidence, not a new production terrain authority.

The runtime restore batch now routes F9 and broad save/combat restoration through
`try_load_world_staged`. It quiesces gameplay, retires generated/navigation
publications, restores the existing owners' durable state, reinitializes native
terrain from restored edits, and awaits tutorial and regional publication.
New Game reuses the same terrain/navigation preparation and final readiness
functions. Initial boot retains synchronous snapshot-data restoration, with all
chunk publication deferred. Save format and route/motor/door authority are
unchanged. Save parsing and some state restoration are still synchronous;
this does not establish a hard frame-time bound.

Mining's new broad failure is associated with streaming status replacing the
tool-requirement notification. Tool-tier rejection still precedes break progress,
but Broad02 did not record its individual physical sub-results. Passive
notifications now yield to active action feedback until expiry; streaming
retries and collision holds remain active. The unchanged assertion now records
ray identity, tool, block existence, break progress and text immediately and
after its original two-frame wait. The HUD priority contract is explicitly
synthetic. All48 changed scripts compile (`godot-qHV2sK`); startup/HUD contracts
pass52/52 in `direct-startup-contract-04.json`. Terrain run05 was launched during
an unfinished agent edit and failed inheritance parsing, not a completed-source
production test. Final-source terrain run06 and headed integration are pending.

Final-source terrain run06 passes11/11 at `atlas-75590047` (`godot-fBO5tW`).
The independently selected floor/air densities exactly match both published SDF
samples; collision differs from their analytic crossing by0.0035635m. No
placement or terrain generation changed to obtain this result.

Frozen headed `candidate-teleport-regional-composed-11` passes28/28 and its
wrapper: natural exit0, zero engine warnings/errors, unchanged sources, clean
owned-process zero. Startup takes130.809s; the11.993s ordinary-input exterior
approach reaches7.84m from the visual bounds, with12 samples and zero terrain
holds. Initial spawn is selected before attachment; no setup relocations.
Inspected spawn, courtyard, home threshold, keep stair exit and wall-furniture
captures. Solid terrain and citadel are visible, the inspected doorway is clear,
and the keep stairs/landing are connected. Haze, dark interior readability and
material grain remain visible. Gatehouse landing01 still clips its camera into
geometry and supplies no usable visual proof. Fixed camera views are not proof
of walking every door/stair or full-citadel NPC traversal.

Performance is explicitly failing: ordinary approach p99=154.4ms, max208.482ms,
38 intervals over100ms, median16.7ms. Rendering maxima: CPU6.199ms/GPU7.520ms;
2258 draw calls and3.274M primitives (shadow pass up to4912 calls/7.240M).
Main callback max184.231ms, navigation snapshot build max178.077ms; last spike
125.668ms, chiefly chunk125.154ms/navigation snapshot119.271ms. These measured
main-thread source filtering costs remain the next performance boundary.
No cold-cache acceptance claim is made.

Broad03 completed158/163 at replay seed `atlas-2000247266`, with the same five
recorded baseline failures (tutorial perimeter lamps, two generated environment
prop checks, character pack readiness and generated render policy). Watchdog
`godot-kL37Ac` records clean engine/cleanup and owned-process zero. Staged save
round-trip and mining pass: iron remains intact with zero break progress under
the wrong tool, and the required Copper Pickaxe message survives the two-frame
observation. This default broad run does not contain the separate combat restore
fixture. `direct-startup-combat-restore-01` finished8/9: restoration clears all
transients, but the setup dodge was rejected as `terrain_unready`. Its pre-act
relocation must await the production motion readiness contract.

Real-menu pair `artifacts/npc/node-production-runs/save-continue-TjycNQ`
(fresh seed `atlas-74140558`) reports both flows passing, with clean watchdogs
`godot-H8VyaV` and `godot-y3rU0P`. Startup wall times are about131.18s New Game
and122.57s Continue. Inspected starter-room and final-home captures. Continue
records zero displacement after observation starts: Mira is already indoors,
then the door closes. This proves menu/save/Continue flow and final state, not
an observed home approach/crossing. The input save was overwritten by graceful
exit, so its final position cannot establish the restored initial position.

Independent audit found an existing loading-gate gap (also present at
`ea691ed`): disabling NPC bodies does not stop their shared autonomy physics
service. TjycNQ accumulated5763 service ticks before observation; the earlier
CBSW8h run already accumulated597. Main now also pauses this existing service
at startup, runtime restore, failure and shutdown, then resumes it with gameplay.
Staged navigation preparation remains callable; route/motor/door logic is
unchanged. Synthetic startup contracts pass54/54 (`direct-startup-contract-05`)
and48 changed scripts compile (`godot-kRNvNf`). Live rerun and immutable
pre-Continue input preservation are pending; this correction is not promoted yet.

Combat restore02 now passes9/9 at the same seed (`godot-2t0Abi`), natural exit0,
clean engine/cleanup and owned-process zero. The fixture awaits the exact
production dodge motion proof before its act phase. Dodge is active before
restore and inactive/cooldown0 afterward, with all projectile/motion transients
cleared and durable-only save data retained. Its dark night screenshot was
inspected; it is not useful terrain/structure visual acceptance.

Continue observation now starts synchronously at the gameplay-release signal,
preserves and verifies the exact input slot/active-seed files before launch,
and requires measured displacement, opening before crossing, strict interior
clearance and later closure. It separately checks shared execution stays paused
through loading. All48 changed scripts compile (`godot-Zclr6R`). The guarded
real-menu pair `save-continue-TSm5JS` passed New Game on fresh seed
`atlas-45237917`: click0.124s, readiness41.274s (41.15s elapsed), live door
interaction42.439s. Its complete starter-room capture was inspected. This is
one fresh-seed sample, not empty-cache acceptance or a controlled speed comparison.

Continue was stopped by the owned watchdog on a preexisting diagnostic error:
`NpcRouteAuthorityV2._maybe_capture_scripted_order_stall_trace` calls
`Node.get("seed_text", "")`, but Node.get takes one argument. The same mistake
exists at `ea691ed` in the collision-recovery trace writer. Both diagnostic
property reads now use the Node API and retain the empty-string fallback for
absent/non-string seeds. No routing, motor, door or traffic decisions changed.
Watchdog `godot-6DI83g` proves forced-stop owned-process zero; this is a failed
run, not clean-exit acceptance. Its exact input slot is preserved with SHA-256
in `continue-input-manifest.json`. Existing NPC contracts pass84/84 after the
fix (`loading-gate-npc-contract-01/report.json`). Fresh guarded pair
`save-continue-FFB0aP` failed on fresh seed `atlas-21834251`: New Game declared
ready but 12s of recorded forward input did not move the player from starter
cell267,-10 toward the door. The starter room is fully visible in its capture.
The old report omitted the movement gate/collision proof; do not infer a cause
from its zero velocity alone. The existing runner now reports physics/wish/hold
state and retains the full final motion proof on failure. This production
behavior blocks promotion pending exact-seed diagnosis.

Exact preserved-input Continue replay at `atlas-45237917` passes after the
trace correction: `continue-replay-loading-gate-01/report.json`, watchdog
`godot-PEe7DM`. This runs the same guarded fixture through real MainMenu Continue
with ordinary gameplay settings, using copied immutable input rather than the
failed run's mutable exit slot. Across227 registered loading samples, shared
execution stayed disabled and service ticks remained0 through release. The
restored position matches the preserved NPC save position (capture rounding
accounts for0.000153m observed difference). Trace physics frames: initial960,
displacement983, door opens2813, crossing2824, strict interior/clearance2895,
door closes2942. The restored-door view and final interior/closed-door view were
inspected. The full sequence is supported by the live position/door timeline;
the screenshots alone do not depict every transition. No broad performance
acceptance follows from this replay. Exact-seed direct-Main motion diagnostic
`spawn-motion-replay-01` reproduces the movement hold at the exact failing seed
through real Main and physics input (explicit seeded diagnostic, not menu/NPC
acceptance). Startup passes; the player moves2.18m then remains held through18s.
The proof names `regional_dependencies_incomplete`: a query for tile16,-1 closes
over the whole town and waits for unrelated tiles18,-1/19,-1/19,0/16,1. The
queried tile's source key remains1377:0:0 while those other tiles change.
`_describe_regional_town` currently expands every intersecting request to full
town bounds/all homes. No closure correction has been applied.

User steering now prioritizes citadel spawn speed and stops the tutorial-town
investigation. Preserve this known regional over-expansion defect; it blocks
general gameplay promotion, but do not let further town-specific investigation
delay the citadel performance cutover. The loading batch is a checkpoint, not
completed architecture acceptance. Latest citadel baseline remains headed11:
130.809s startup,28/28 diagnostic checks,208.482ms worst approach frame and
178.077ms maximum navigation snapshot preparation.

The ignored `navigation-filter-worker-draft` is a design/prototype only. It
lacks producer capture, accepted-result integration and regional consumption;
it must not be applied partially or cited as an implemented performance fix.
