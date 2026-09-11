# Regional navigation publication candidate

Parent `5fc79d9`, branch `codex/world-streaming-architecture`. This candidate is
not yet a regional gameplay-readiness cutover. Whole-site scene publication still
gates its source artifacts, and the streaming coordinator lacks completed
structure/navigation regional acknowledgements.

## Current changes and ownership

Worker preparation compiles the existing source clearance samples into immutable
navigation tiles. The scene publication owner returns them only with the current
source binding, live root under its original parent, and actual registered door
leaves. Missing admission, world reset, retirement, changed parent and lost door
registration remain pending rather than claiming an empty ready world.

The navigation adapter consumes each door from that source owner, including when
the door body and its certified interior support occupy different tiles. Ordinary
door identity, state, opening and route execution remain in their existing owners.
The whole-artifact unresolved-crossing summary now includes doors as well as stairs.

Before mesh upload, the existing navigation mesh builder combines exactly touching
axis-aligned rectangles from the same declared source geometry group. It retains
every original surface ID in the installation receipt. Single-axis grades merge
only across their level axis, preserving all corner heights. Different heights,
holes and irregular polygons are preserved. Shared sample and tile boundaries now
derive from integer grid coordinates, avoiding accumulated float32 discrepancies
at kilometre-scale coordinates. No baking backend, raster size, warning setting,
route search, motor or door execution is changed.

## Evidence and failures retained

- `regional-owner-job-02`: 392 synthetic publication/lifecycle checks pass, including
  stale binding, same-transform reparenting, cancellation and source retirement.
  Its watchdog records exit 0, clean cleanup and zero owned members. Attempt 01
  passed its checks but its wrapper expected a report file where this fixture
  expects a directory; it is retained as a failed invocation.
- `regional-owner-nav-02`: existing navigation-world suite, 86/86 pass. Watchdog
  `godot-lqSk4c`. Earlier `regional-owner-nav-01` also passed before rectangle merging.
- `regional-owner-nav-lifecycle-01.json`: 39 navigation lifecycle/receipt and
  synthetic coverage checks pass. Watchdog `godot-4X79QR`.
- `candidate-teleport-regional-nav-owner-01`: real Main scene completed generation,
  rendering and captures, then the new publication diagnostic incorrectly assumed
  terrain surfaces have explicit IDs. Terrain uses cell/span IDs. The error
  watchdog stopped the job and proved zero owned processes; this is not a passed
  run. The fixture now derives required IDs through the production descriptor.
- Its saved first tile, `navigation-tile--206,-174.bin`, independently exposed a
  production synchronization warning: 37 edge errors among 2,252 polygons. Exact
  edge inspection found neither zero-length nor multiply owned exact edges; the
  dense internal sample boundaries conflicted in server synchronization.
- `regional-owner-tile-replay-03`: replay of that unchanged actual tile through the
  production service now has 275 polygons, retains all 2,327 declared surface IDs
  and its door link, and receives a ready source-matched installation receipt.
  Logs are clean; exit 0, cleanup passed and owned zero. Earlier replay 02 removed
  the warning but observed before synchronization completed. Replay 03 waits on
  the actual receipt with a bounded deadline. This is saved-source service
  evidence, not live player/NPC acceptance.

The existing headed candidate now captures views first, then submits actual tile
snapshots through the live production navigation service and records required
surface/crossing installation receipts. Saved tile binaries preserve geometry;
JSON progress omits repeated full-geometry signature strings. This diagnostic
does not prove route connectivity, NPC movement or frame pacing.

## Next verification

`candidate-teleport-regional-nav-owner-02` finished the real Main scene and all
42 tile installation receipts covered 164,527 declared surfaces and 77 links.
However, 29 engine synchronization warnings made the wrapper fail. Natural exit
was 0, cleanup passed and no owned processes remained. This is not a passed run.
The worst measured tile installation was 439.264ms; publication is not bounded yet.

The saved snapshots were recompiled from their accepted source while retaining
the saved live surface selection. `regional-owner-recompiled-02` retained every
saved surface ID. `regional-owner-all-replay-01` installed these 42 tiles through
the production service in one shared map and received complete receipts, but one
engine warning still reports two edge errors. The runner correctly exits 1.
This is service diagnostic evidence, not live gameplay acceptance.

`regional-owner-all-edge-audit-06` identifies the remaining crowded raster cell:
tile `-210,-176`, the approximately 0.19m square terminal fragment of source paving
segment 23. The source contains adjacent narrow paving segment 86, but that
segment is absent from the saved published surface selection near the fragment.
Giving adjoining parts a common source geometry group consequently did not remove
this isolated fragment. Determine whether source sampling or live filtering omits
the adjoining support before changing geometry. Do not drop the fragment, fill a
gap speculatively, or tune server raster settings to conceal the discrepancy.

The follow-up `regional-owner-small-support-03` proves that the fourth corner of
the fragment violates the existing 0.52m clearance from source foundation
`castle_terrace_block_02_left_17`; the diagonal predicate misses it. Source
publication and live building-surface filtering now explicitly check the full
rectangle through the existing clearance owner. Segment callers keep the original
predicate and default behavior. `regional-owner-recompiled-03` rejects 439 source
patches for actual footprint obstruction, recording the removed IDs explicitly;
it does not claim unchanged surface parity. No physical/visual geometry is removed.

`regional-owner-all-replay-02` then installs all 42 saved/recompiled tiles with
complete declared receipts and zero engine warnings, natural exit 0, cleanup
passed and authoritative zero owned processes. `regional-owner-nav-lifecycle-02`
passes 45 synthetic/service checks, including grade/group identity and full
rectangle clearance; watchdog `godot-eyp3g1`. `regional-owner-nav-03` passes 86
navigation-world checks. `regional-owner-job-03` passes 392 publication/lifecycle
checks. A preceding job invocation supplied a disallowed full source path to the
generic contract wrapper; it was rejected before launch and corrected to the
existing runner's filename convention.

## Full headed candidate 03

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-regional-nav-owner-03
```

All checks pass, with natural exit 0, no engine warnings/errors, clean cleanup,
zero owned processes and no changes to the frozen sources. Initial spawn is
selected before player attachment and terrain startup, with no setup teleports.
Startup is 87.330s and the whole diagnostic including captures/navigation is
187.046s. Existing dependency caches were present: this is not cold acceptance.
The scene audit finds 3,312 collider shapes with zero identity mismatches, 20
doors, 178 furniture bodies and all source crossings resolved. All 42 live tiles
receive revision-matched receipts for 163,974 surfaces and 77 links.

Inspected initial spawn, ready exterior, overview 2, gatehouse stair base and a
home door. Nearby terrain is drawn at release; the citadel and stair landing are
visible. The close-up views remain very dark and the distant terrain boundary is
visible from the elevated diagnostic camera. These are unresolved visual limits.
The input-driven approach passes, but this runner does not exercise NPC traversal
or walking every door/stair connection. Camera inspection placements are diagnostic.

The short approach's post-draw cadence p99 is 17.4ms, max 19.832ms. Whole-site scene
publication reaches 80.650ms and the worst tile install takes 401.567ms despite only
28 merged polygons (17,619 retained surface identities). Main-thread descriptor,
identity and registration costs still need bounded preparation/publication.
Startup includes a 2,619.258ms post-draw interval. These measurements do not meet
the complete performance contract and are not a five-minute traversal campaign.

Existing successful ordinary New Game/Continue loading-screen evidence remains in
`WORLD_STREAMING_CONTINUE_2026-09-11.md`.

## Broad regression and pending attribution

```text
node tools/run-playtest.mjs -Visible -Seed atlas-648215039 -ReportPath artifacts/citadel-runtime-integration/regional-owner-broad-01/report.json -ProgressPath artifacts/citadel-runtime-integration/regional-owner-broad-01/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/regional-owner-broad-01/playtest.png -TimeoutSeconds 600
```

The run finished at 158/163. Watchdog `godot-DWuGe1` records natural functional
exit 1, no timeout or forced cleanup, cleanup passed and authoritative zero owned
processes. Inspected its final screenshot: terrain, the actor/dialogue and held
item are present; some trees visibly remain incomplete.

- `generated_environment_prop_visuals` and
  `generated_environment_prop_authority_and_static_fallback`: tree recipe still
  building at 720 fixture frames. This failure class was recorded on the unchanged
  reference with the earlier seed.
- `character_asset_pack_ready`: same previously recorded 40 assets / 11 families.
- `sanctuary_beacon_raid_system`: `contested false`, all other listed conditions
  true. This fixture calls charge updates directly without physics between them;
  it is not independent evidence of a live combat regression.
- `town_exit_slope_apron`: max step 1.47m against the unchanged 1.24m limit,
  radius 25, apron 22, direction `(-1,0)` at offset 35. This is a source terrain
  rule failure and must not be waived because the navigation candidate passed.

The full matching headed baseline run completed in the independently verified clean `d6314ed`
checkout `../voxel-biome-world-godot-streaming-reference-20260911`, output
`artifacts/citadel-runtime-integration/regional-owner-baseline-broad-01`. Same
command/options, with those output paths substituted. It also finishes at 158/163:
every pass/fail result and all five failure detail strings match the candidate
exactly. Watchdog `godot-kc6625` records natural functional exit 1, no timeout,
cleanup passed and authoritative zero owned processes. No new or worsened broad
failure is demonstrated by this comparison. The wrapper seed affects this town
probe; the earlier broad run using `atlas-338921745` was not a same-seed comparison.
These baseline failures remain defects, not waived acceptance checks.

The existing ordinary headed New Game/Continue runner passes on this
candidate in `artifacts/npc/node-production-runs/save-continue-Ri8NOS/`:

```text
node tools/npc/run-tutorial-save-continue-playtest.mjs --visible --timeout-seconds 360 --stale-progress-seconds 90
```

Random seed `atlas-76288624`, two real main-menu processes, no gameplay-affecting
flags, no fixed frame override, 1280x720. Both stages and the forbidden-call guard
pass. New Game click-to-unlock is 38.921s; Continue click-to-first observation is
35.382s (an upper bound including brief fixture setup). These use existing asset
dependencies and do not constitute the 1080p cold-cache performance campaign.

Both stage timelines show `Drawing nearby terrain`, `Nearby terrain displayed`,
then `Gameplay prerequisites ready`. The player opens the starter door through
input, acknowledges dialogue, and saves the generic go-home intent. Continue
restores it through ordinary game systems. Its trace records home-door opening at
56.449s, closure at 57.866s and settled strict-home arrival at 58.279s wall time.
Inspected the first restored player view and final observer capture: the latter
shows the NPC inside a furnished, floored home with the door closed. The first
observation already places her 24.729m from the starter porch, so the reported
porch-clearance delay is not a fresh departure measurement. This is live tutorial
home/save regression evidence, not citadel crossing or sustained traversal proof.

Watchdogs `godot-ySkEhw` and `godot-kqwnDn` both record natural exit 0, clean cleanup,
no forced cleanup and authoritative zero owned processes. No engine errors or
warnings were reported. The baseline checkout remains unchanged at `d6314ed`.

## Next architectural cutover

Whole-site publication still gates tile source delivery. Regional owner
acknowledgements, retained pending navigation requests and bounded worker-prepared
mesh/identity publication are unfinished. In particular, a pending adapter source
currently returns an empty snapshot; its consumer must retain demand rather than
cache an empty ready result. Read-only inspection also flags live collision bounds:
fallback records start at the body origin vertically, while pitched box XZ bounds
use the center plane. These need authoritative-volume treatment before claiming
regional physical completeness. Route search, motor and traffic remain unchanged.

Broad gameplay regression and real movement remain required. The current source
publication work does not satisfy bounded uploads, regional traversal readiness,
the cold-load campaign, distance tiers or the five-minute 1080p performance target.
