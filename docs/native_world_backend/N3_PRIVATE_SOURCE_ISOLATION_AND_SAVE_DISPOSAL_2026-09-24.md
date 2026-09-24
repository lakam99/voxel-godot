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
maximum-size file-backed gameplay. An early load failure can still release a
decoded save outside this successful retirement path. External snapshot
overrides intentionally retain their terrain aliases. Native terrain query,
collision and save authority cutover, N3 acceptance and final Gate 5 remain
open.
