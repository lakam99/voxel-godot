# N3 private source isolation and decoded save disposal

The independent Stage A review found that private source construction called
`CitadelTerrainAdmission.finalize_town_inputs`. That changed shared production
town state during private staging and source rechecks. Main now explicitly
finalizes production town inputs after tutorial readiness and before staging.
The private candidate reads a deep snapshot of already-finalized town inputs;
an unfinalized private request fails without changing shared state. The
focused transaction contract checks this failure, stale-source rejection and
cancellation against the admission generation and town map.

File-backed v2 saves also left a large decoded terrain Array for synchronous
Variant destruction. After script restore and native import have both
completed, Main retires this owned decoded terrain through 64-record steps
with a 3 ms per-frame work target during visible loading. An in-memory
`snapshot_override` is borrowed and remains untouched. The retirement service
reports its own largest step and final alias release separately from the
frame-loop work measurement.

Verification on the isolated `codex/n3-save-disposal` branch:

- `node tools/run-n3-legacy-terrain-load-transaction.mjs` passed, including
  the town state isolation assertions. Report:
  `artifacts/native-world-backend/n3-legacy-terrain-load-transaction-1790224028017-c5350635/report.json`.
- `node tools/run-n3-native-world-source-request.mjs` and
  `node tools/run-project-compile-smoke.mjs` passed after the isolation edit.
- `node tools/run-n3-decoded-save-retirement.mjs` passed a synthetic 65,536
  record disposal diagnostic. Report:
  `artifacts/native-world-backend/n3-decoded-save-retirement-1790223378065-c8d2c4d4/report.json`.
  In that process, dropping the last unretired terrain alias took 169,700 µs.
  The retirement cursor finished in 1,025 advances, with a largest advance of
  1,344 µs and final release of 10 µs. Owned-process receipt:
  `artifacts/node-tools/process-runs/godot-npfJmS/watchdog.json`.
- Independent review found that empty section removals initially consumed no
  step budget. They now count as work units. The repeated diagnostic passed:
  `artifacts/native-world-backend/n3-decoded-save-retirement-1790225022643-2f63acc2/report.json`,
  owned receipt `artifacts/node-tools/process-runs/godot-fw8iDb/watchdog.json`.
  It processed 257 empty sections and one legacy record in five advances;
  only 64 sections disappeared in the first advance and the legacy entry
  remained pending. The 65,536-record case still passed, with a 1,140 µs
  largest advance and 16 µs final release. The raw last-alias drop in this
  process took 160,759 µs.
- `node tools/run-n3-private-main-load-headed.mjs` passed real-menu New Game,
  runtime Continue with a borrowed override, and fresh-process file-backed
  Continue in Forward+. Reports and pending/ready captures:
  `artifacts/native-world-backend/n3-private-main-headed-1790224237814-3d372378/`.
  Owned receipts:
  `artifacts/node-tools/process-runs/godot-gApuck/watchdog.json` and
  `artifacts/node-tools/process-runs/godot-JzEB5N/watchdog.json`.
  Fresh Continue reported `save_retirement` ready, one advance, 17 µs
  maximum frame-loop work, and zero durable terrain records. New Game
  reported the external override retained. Gameplay readiness was 125,473 ms
  on New Game and 132,670 ms on fresh Continue in this fixture.
- `node tools/run-n3-private-main-load-headed.mjs --historical-from
  artifacts/native-world-backend/n3-private-main-headed-1790224237814-3d372378`
  passed historical terrain-only v2 Continue. The native transaction admitted
  20 records; the decoded save cursor retired its one legacy entry. Report and
  captures:
  `artifacts/native-world-backend/n3-private-main-headed-1790224684874-edde2f95/`.
  Owned receipt: `artifacts/node-tools/process-runs/godot-YwZXbA/watchdog.json`.
  Gameplay readiness was 119,881 ms in this fixture.

These headed checks confirm private staging alongside the current script and
Voxel Tools gameplay authorities. They are not normal-flow UX or matched
frame-cadence acceptance: the fixture takes roughly two minutes to reach
gameplay readiness, and its fresh save has no edited terrain. The synthetic
disposal result does not prove exclusive ownership for every file-load path or
maximum-size file-backed gameplay. At that checkpoint an early load failure
could release a decoded save outside the successful retirement path; the
retained-owner change below addresses that path. External snapshot
overrides intentionally retain their terrain aliases. The 3 ms Main work
target is cooperative; one individual advance cannot be preempted. Native terrain query,
collision and save authority cutover, N3 acceptance and final Gate 5 remain
open.

## Matched Stage A startup comparison

`node tools/run-n3-stage-a-matched-startup.mjs --project <absolute-worktree>
--label baseline|candidate` launched the unchanged
`MainMenuStartupSmokeRunner.gd` on each source. Both runs used seed
`n3-private-main-headed`, Forward+ at 1280×720, fixed FPS 60, a fresh Godot
process and the debug GDExtension built from that source. The baseline was
exact commit `d2a3817` with DLL SHA256
`EF6C272061BFB852A19FFAE189113358FBA1BC398B320DBDE1776334A8B6C353`.
The candidate was commit `60aba0d` (this Stage A branch plus the neutral
runner) with DLL SHA256
`253CDF67D07BB3448AB40D3E5ADABCD1FB348B3F2507E5443627E42AF01AF4BF`.
One-time import and native build work were outside the measured launch.

| Source | Gameplay ready | Launch elapsed | Largest callback interval, ending at |
| --- | ---: | ---: | ---: |
| Baseline `d2a3817` | 100,541.679 ms | 100,585 ms | `save_restore` 7,244.089 ms |
| Candidate `60aba0d` | 100,470.490 ms | 100,511 ms | `save_restore` 7,281.445 ms |

Baseline report:
`artifacts/native-world-backend/n3-stage-a-matched-startup-baseline-1790226626741-1f487f15/startup-report.json`,
owned receipt `artifacts/node-tools/process-runs/godot-efxU06/watchdog.json`.
Candidate report:
`artifacts/native-world-backend/n3-stage-a-matched-startup-candidate-1790226738918-f79ba2d8/startup-report.json`,
owned receipt `artifacts/node-tools/process-runs/godot-WMGN1d/watchdog.json`.
Both reports passed full startup-readiness assertions.
Both owned watchdog receipts show natural root exit, no timeout or forced
cleanup, and authoritative zero remaining job members. Candidate gameplay
readiness was 71.189 ms earlier in this one pair, which is measurement noise
for a roughly 100-second load. Its private native load domain became ready
at 21,873 ms with a 15.543 ms reported callback interval; that interval is
not exclusive Stage A CPU time. The largest interval on both sources ended at
the `save_restore` pending update, after scene, player, NPC and HUD setup; the
row does not attribute the elapsed time to save reading. This comparison
supports no startup-speed claim and is not a
whole-frame-cadence trace, unflagged ordinary New Game, or Gate 5 acceptance.

## File-backed 4,096-record Continue diagnostic

`node tools/run-n3-private-main-load-headed.mjs --dense-from
artifacts/native-world-backend/n3-private-main-headed-1790224237814-3d372378
--dense-records 4096` passed a single headed Forward+ Continue. The runner
copied a synthetic v2 slot with one terrain section and 4,096 durable cells
far from spawn. The copied input was 1,513,946 bytes, SHA256
`70bd0a6fee015e4adf32bf0b2824ded50241a789abc91f10fd634ae7803e64df`.
The report and pending/ready captures are in
`artifacts/native-world-backend/n3-private-main-headed-1790231205110-d4f71d00/`;
the owned receipt is
`artifacts/node-tools/process-runs/godot-77h58K/watchdog.json`. The receipt
proves natural exit and authoritative zero remaining owned processes.

The private transaction admitted 4,096 records in 22 advances, at most 256
records per advance. Its largest advance took 6,895 µs, above the shared
6 ms gameplay publication envelope, while visible loading remained active.
Decoded terrain retirement removed all 4,096 records in 65 advances across
five frames. Its largest advance was 350 µs, largest measured frame-loop
work was 3,325 µs (above the cooperative 3 ms target), and final alias
release was 2 µs. Gameplay readiness was 123,017.649 ms. The ready capture
visibly shows the private native terrain ready; it does not show a native
gameplay authority cutover.

The largest observed callback-to-callback frame gap before private staging
was 7,612 ms. Main's largest startup row was 7,519.165 ms, labeled
`save_restore`/`Loading save`. That label marks the *end* of the interval:
the preceding `Preparing audio 22/22` row was at 831.315 ms and `Loading
save` was at 8,350.480 ms. `MainCore._run_deferred_startup_boot` performs
scene, tutorial, player, hostile, NPC, projectile, motion, held-item and HUD
setup between those rows. It calls `try_load_world` only *after* recording
`Loading save`. The following 1,972.915 ms interval ends at `Tutorial
requirements ready` and includes save restore plus tutorial setup; it is
also not an exclusive save measurement. The title menu may read/validate a
save before constructing Main, outside this startup timeline. This single
synthetic run gives no incremental 4,096-record load cost, ordinary edit
creation evidence, full-size file-backed proof, normal menu-input latency,
or whole-game frame-cadence acceptance. No 65,536-record headed run followed.

## Shadow failure gate and retained decoded-save owner

Independent review found that a failed *private* candidate aborted ordinary
Main boot while script generation and Voxel Tools remained gameplay authority.
Initial New Game/Continue, runtime Continue, and runtime New Game now use one
explicit decision: a private failure records `private_native_load` as excluded
and continues the script-backed loading path. The same decision fails closed
when native authority is requested. Shutdown cancellation still fails. A
private stage that cannot acknowledge drain remains owned by Main; its save
input is not retired while that reader may still hold aliases.

Main now retains decoded file-backed snapshots before script restore and
holds the retirement cursor through failure and quit. The title menu drains
these owners before freeing a failed Main on retry or exit; an unacknowledged
drain leaves the failed instance owned and blocks replacement. The cursor
reports malformed section data without
releasing its owner, then drains known section/cell and legacy arrays in
64-unit steps. Only acknowledged drain permits Main to clear the snapshot
alias. An unprocessable owner remains retained and stops graceful shutdown
instead of dropping its last alias. Snapshot overrides remain borrowed.

Focused verification after this change:

- `node tools/run-n3-decoded-save-retirement.mjs` passed a synthetic
  malformed `cells` case: failure retained the owner, and 129 sections drained
  in three advances, with 65 remaining after the first. Its 65,536 valid
  records and 257 empty-section budget checks also passed. Report:
  `artifacts/native-world-backend/n3-decoded-save-retirement-1790232894337-d300cd58/report.json`;
  owned receipt `artifacts/node-tools/process-runs/godot-Hq94o2/watchdog.json`.
- `node tools/run-n3-legacy-terrain-load-transaction.mjs` passed the private
  failure decision contract: shadow failure permits the legacy authority and
  an authoritative failure does not. It also retained a decoded snapshot
  before a rejected script restore, and the title menu refused to free a
  failed owner until the drain acknowledged. Report:
  `artifacts/native-world-backend/n3-legacy-terrain-load-transaction-1790232850080-72cf6e9f/report.json`;
  owned receipt `artifacts/node-tools/process-runs/godot-Z2a2K4/watchdog.json`.

Both receipts prove natural exit and authoritative zero remaining owned
processes. These focused contracts do not prove a real Main boot with an
injected private failure, headed failure presentation, a maximum-size
file-backed failure path, or native terrain/collision/save authority cutover.

### Invalid-start and failed-instance drain review repair

Independent review of the shadow-failure commit found that malformed
`terrainVolume`, `sections` or legacy `terrain` could fail before the
retirement service retained the decoded snapshot. The service now takes the
snapshot first, marks an invalid start as failed, and drains its JSON
containers through a cursor capped at 64 work units per advance. Main can
therefore drain that failed owner before a title-menu retry/free. A runtime
file-backed snapshot is retained before seed validation; a wrong-seed
snapshot is retired before the quiesced world resumes. In-memory overrides
remain borrowed. During shutdown, startup progress still records a row and
yields a frame, but does not advance Citadel publication, streaming demand or
local-light publication.

- `node tools/run-n3-decoded-save-retirement.mjs` passed all three invalid
  initial payload types, each retained through first failure and drained over
  multiple bounded advances; the prior malformed-cell, 65,536 valid-record
  and 257 empty-section checks still passed. Report:
  `artifacts/native-world-backend/n3-decoded-save-retirement-1790233309276-7f5ae1ab/report.json`;
  owned receipt `artifacts/node-tools/process-runs/godot-7zTt8C/watchdog.json`.
- `node tools/run-n3-legacy-terrain-load-transaction.mjs` passed a MainCore
  failed-instance drain with invalid initial sections, zero structure and
  streaming dispatch while shutdown is set, and file-backed wrong-seed
  runtime restore with its decoded sections empty before return. Report:
  `artifacts/native-world-backend/n3-legacy-terrain-load-transaction-1790233321595-fe848af0/report.json`;
  owned receipt `artifacts/node-tools/process-runs/godot-eOCsCZ/watchdog.json`.

These are focused headless service and MainCore contracts. They do not prove
whole-game frame cadence, arbitrary corrupt JSON scalar release cost, an
ordinary headed failure/retry sequence, or any native gameplay authority.

### Nested malformed-cell disposal follow-up

The valid-start failure drain previously removed a section with a non-Array
`cells` value as one work unit. A nested Dictionary there could be large.
Structural failures during ordinary retirement now enter the same bounded
JSON-container cursor used for invalid starts. A focused fixture with 512
nested malformed entries retained 505 after its first advance and completed
in 77 advances; the ordinary 65,536-record and empty-section checks still
passed. Report:
`artifacts/native-world-backend/n3-decoded-save-retirement-1790234061802-5450e473/report.json`;
owned receipt `artifacts/node-tools/process-runs/godot-EsSNT5/watchdog.json`.
This run proves bounded container work units and functional drain for that
synthetic nested shape. It does not bound arbitrary scalar destruction or
whole-game frame cadence. Its valid-save largest advance was 16,084 µs in
this one process, so it makes no frame-budget acceptance claim.

### Oversized nested values on the ordinary retirement path

A subsequent synthetic fixture found that ordinary successful retirement
still popped a decoded cell whose metadata held 512 nested entries in one
work unit. The service now checks a container tree against a 128-value
atomic cap. Small records keep the existing 64-record advance behavior;
larger cell, section, legacy and remaining snapshot containers use the same
64-unit iterative drain cursor as malformed input. The shared cursor drains
one nested edge or leaf per unit. The 512-entry cell retained 505 entries
after its first advance and completed in 57 advances. A separate oversized
section plus top-level payload completed in 114 advances. The 65,536-record
ordinary fixture still completed in 1,025 advances with 65,536 retired
records. This is a node-count bound, not a byte-size bound for an individual
string or scalar value.

`node tools/run-n3-decoded-save-retirement.mjs` initially failed the added
nested-cell check: the first advance completed with all 512 metadata entries
unchanged. Report:
`artifacts/native-world-backend/n3-decoded-save-retirement-1790235242915-49cc1f78/report.json`.
After the cursor change it passed including nested cell, section, snapshot,
malformed and 65,536-record checks. Report:
`artifacts/native-world-backend/n3-decoded-save-retirement-1790235361222-e8ae92de/report.json`;
owned receipt `artifacts/node-tools/process-runs/godot-UQ3UZ3/watchdog.json`
proves natural exit and zero remaining job members. Its largest ordinary
advance was 1,581 µs in that process. No whole-game frame-cadence claim
follows from the synthetic fixture.

The adjacent `node tools/run-n3-legacy-terrain-load-transaction.mjs` retry
was inconclusive in this isolated worktree: Godot could not resolve
`MainPropFactory.gd`, then the run-local stop request terminated the owned
job before a report was written. Receipt:
`artifacts/node-tools/process-runs/godot-Qx40hP/watchdog.json`. The earlier
passing contract above remains the pre-change evidence; the combined branch
still needs its own compile/transaction check.
