# Actual citadel scene publication diagnostic

Branch `codex/citadel-visuals-clean`, starting at `46bb785`. This advances the
ordinary-publication checkpoint; it does not enable unfinished cities in normal
gameplay or establish headed readiness.

## Implementation

BuildingScenePublicationJob consumes a one-shot prepared source and admitted
profile. It creates a unit-scale, upright site root at the profile's world
origin, then advances the existing building and furnishing publishers and calls
the existing Main tree-request adapter. No recipe rebuilding, furniture filtering,
tree replacement or private door/navigation service is introduced.

BuildingPartPublisher now offers compact preparation/status/finalization results
without copying its full diagnostic reports each time. Legacy finish_publication
still returns the full report. Optional publicationSiteId namespaces door IDs
across sites without mutating blueprint geometry or its canonical recipe ID.

The job retains deferred tree requests, distinguishes durable-harvest skips,
and waits for actual shared-queue visual completion and its GeneratedTreeVisual
node. Scene-ready is explicitly separate from gameplay-ready. Cancellation
invalidates immediately, then removes one scene leaf at a time on main. Detached
data and publisher-held Resource references are transferred to the existing
retirement worker after node references have been removed. Resources are not
misrepresented as CPU-only payloads. This is reference ownership transfer, not
worker-side creation/modification of live render objects; Godot documents
cross-thread resource-reference handling separately from unsupported concurrent
resource mutation: [thread-safe APIs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html).

Requested slices are 2,500 microseconds, accepting only 1..4,000. Atomic and
slice overruns are measured. A deadline between calls cannot make the existing
indivisible publisher calls bounded; current measurements explicitly fail that
gate. The normal streaming service therefore does not launch this job yet.

## Evidence and limits

All artifact paths below are under `artifacts/citadel-runtime-integration/`.
The actual fixture is `actual-site-source-05/result.bin`, SHA256
`7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`:
world `atlas-1492`, region `(1,-3)`, recipe `1298433643`, scale `1.25`.
It is loaded/frozen and prepared off-main, not generated anew for this test.

```powershell
./tools/run-building-scene-publication-contract.ps1 -Phase facade -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-facade-01
./tools/run-building-scene-publication-contract.ps1 -Phase actual -OutputDirectory artifacts/citadel-runtime-integration/scene-publication-actual-04
```

The wrappers record source hashes, phase/seed, logs, report and owned-process
watchdog. Actual runs also write a progress file. A fail-fast watcher requests
owned-process shutdown on engine errors; no process-name kill is used.

- Facade: 36/36 checks, including unchanged source, site-specific door metadata,
  legacy default IDs, compact status, full compatibility summary and reset.
- Initial tiny job controls: 46/46, with synthetic prepared proofs/trees and
  real small publishers. They cover deferred requests, stale holder rejection,
  cancellation before begin/after collision/during tree submission and cleanup.
- Final tiny controls `scene-publication-job-02`: 65/65, including cancellation
  from a publisher's finish callback, loss of a previously completed tree while
  another remains pending, and external root loss. External removal first
  balances its fake registration; that test does not excuse an owner skipping
  cleanup hooks in the live game. Natural exit 0, empty stderr, owned zero.
- Existing PavingFootingPublisherContract: 139/139. Direct command and cleanup
  proof are in `scene-publication-paving-01/watchdog.json`.
- Actual publication `-02`: 58/58, empty stderr, natural exit 0 and authoritative
  zero owned processes. All 4,703 building parts and 210 furnishings publish;
  3,179 blocking collision shapes match source dimensions/transforms, all 20
  doors receive site-specific IDs, and all four trees complete through the
  real production tree queue. A physics overlap after synchronization hits the
  expected real collision body. Incremental teardown and worker cleanup finish.
- Actual publication `-04`: 61/61, clean wrapper exit and owned zero. Adds
  explicit unique mesh/material weak-reference release after retirement and
  a complete render/metadata fingerprint: 2,703 render nodes, 128 unique meshes.
  `render-baseline.json` records native geometry arrays, transforms, instance
  buffers and material properties; this is a comparison artifact, not a screenshot.
  Audit/hash work is deliberately outside scene-publication slice measurements.
  Publication elapsed 16.676 seconds; paving maximum 235.782 ms, metadata maximum
  102.508 ms, masonry setup 10.744 ms and history setup 4.510 ms. Budgets still fail.
- Actual `-05` repeats 61/61 with clean natural exit and owned zero. Every render
  and metadata fact matches `-04` exactly, not only the summary digests. This
  establishes the pre-optimization comparison baseline for the next chunk.

Actual Main methods are used through a subclass suppressing gameplay boot and
Main's frame loops; tree queue processing remains real. There is no terrain,
real menu/New Game, player approach, resident, registered door service or save
act. One physics probe is not traversal acceptance. Headless construction is not
visual approval. The earlier exact source/preparation evidence remains separate.

Actual `-01` retained two failed audit assertions. The audit incorrectly included
explicitly labeled door_interaction_proxy shapes as blocking geometry and chose
an Area3D proxy as the expected physics body while querying bodies. The corrected
audit uses the publisher's blocking_part role; it still checks every blocking
part's identity, dimensions and world transform. No production geometry changed
to fix that audit. The failed report is preserved.

Actual `-03` is INVALID despite its own passed report. A new test-only mesh audit
called an ArrayMesh script method on SphereMesh, so the nested audit aborted and
omitted checks. The external wrapper rejected the engine error; both owned
processes from the latest tiny/actual runs exited. `-04` uses subtype-correct
native arrays and sets an explicit false completion check before entering the
audit, overwriting it only after exhaustive inspection and baseline writing.
No geometry is changed or omitted to repair this audit.

Final same-condition NPC regression: `scene-publication-npc-{contract,motor,nav_world,route}-01`,
seed `atlas-1492`, both time modes, fixed 60 FPS, isolated userdata, existing
NpcAutonomyTest scene through the owned watchdog (45-second cap). Results:
84/84, 48/48, 84/84, 130/132. First three stderr files match the previous service
checkpoint byte-for-byte. Route retains the two day/night
`npc_route_diagnostic_home_collision_lattice_exact_detour` failures with the same
32,000-us budget reason. The critic confirmed route stderr exactly matches the
original 244-header baseline; the previous service run had 250 headers from
additional visits inside that same timed diagnostic. No new regression found.
All four jobs have authoritative zero owned members. This does not repair or
claim a passing NPC baseline; the user's explicit deferral remains in force.

## Measured bottlenecks (actual -02)

Publication after background preparation took 16.173 seconds in this headless
fixture. This is not a normal-game load-time measurement.

| Operation | Maximum measured time |
| --- | ---: |
| One building part: castle_compound_paving_segment_00 | 232.817 ms |
| Collision-record metadata copy/replacement at flush | 114.514 ms |
| Static rendering batch flush, excluding metadata | 3.398 ms |
| Masonry setup | 10.238 ms |
| Surface-history setup | 3.240 ms |
| Paving setup | 0.705 ms |
| Paving revalidation | 0.005 ms |

Metadata publication ran 17 times and consumed 877.389 ms cumulatively. It is
not the cause of the 232.817 ms paving-part call: separate part timing proves
that call is independently expensive. Finalization's combined maximum was
126.368 ms. Masonry advancement also exceeded budget. Furniture and tree
submission were small in this run; that is not a universal timing guarantee.

Next work is incremental paving descriptor/publication and incremental metadata
flush, preserving complete geometry and records; masonry setup/advance remains
an independent budget issue. No test Boolean overrides measuredBudgetsMet=false.

## Remaining release conditions

Cancellation during publisher callbacks remains terminal, all trees are rechecked
at scene-readiness commitment, and Resource lifetime checks now pass in the
headless fixture. The independent critic approved the focused diagnostic commit
after inspecting final source identities, actual04/05 fact equality, tiny controls
and NPC evidence. These controls do not prove headed driver behavior or owner-side
live cleanup, and do not approve ordinary activation or headed tests.
Before normal activation: remove measured stalls, prevent the player from entering
unfinished geometry using the shared movement/readiness contract, balance tree
registrations, finish authorized shared-door registration/cleanup, and retain
unload/re-entry/save/Continue reconstruction. Protected door cleanup permission
is pending; no private replacement is allowed. Then seek headed approval for
real-game visual, gate, terrain-continuity and performance acceptance.
