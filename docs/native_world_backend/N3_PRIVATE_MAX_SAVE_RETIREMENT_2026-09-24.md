# N3 private load: maximum v2 save retirement

The Stage A Main load candidate accepts at most 65,536 durable terrain
records. Its original committed-owner release destroyed the native backend on
Main. A focused full-limit diagnostic admitted 65,536 records and measured
8.1 ms in the native backend release call in one run, with an 8.1 ms total
release. A separate passing run measured 11.3 ms total. The first diagnostic
run produced a functional report but failed owned-process cleanup because the
fixture omitted `main.free()`; the corrected fixture exited with zero-member
proof. The reports remain under `artifacts/native-world-backend/`.

The native adapter now provides a private retirement lifecycle for an idle,
committed staged-save candidate with its exact import generation. It transfers
the pure C++ world state and shaping registry to one owned worker, refuses
active import, staged edits, retained voxel demand or worker state,
and retains the `NativeWorldBackend` object until `poll_private_staged_save_retirement`
acknowledges the worker and joins it. Main's `NativePrivateMainLoadStage`
polls across frames before releasing its backend reference. If retirement
cannot start or acknowledge, the stage retains the owner and fails explicitly.

Verification on the rebuilt debug GDExtension:

- `node tools/run-n3-private-max-save-retirement.mjs` passed:
  `artifacts/native-world-backend/n3-private-max-save-retirement-1790222158519-1fc661d6/report.json`;
  owned process `artifacts/node-tools/process-runs/godot-VgqpCn/watchdog.json`.
  It admitted 65,536 records and rejected a mismatched retirement generation;
  the largest advance was 4,320 µs. Worker retirement acknowledged after one
  process frame. Retirement request took 60 µs, its poll 22 µs, and the final
  backend/transaction release 15 µs. The diagnostic also
  measured 149 ms to release its last decoded save
  `sections` alias. This is a distinct unbounded GDScript/Variant disposal
  cost, so maximum-size whole-save teardown is still a cutover blocker.
- `node tools/run-n3-legacy-terrain-load-transaction.mjs` passed:
  `artifacts/native-world-backend/n3-legacy-terrain-load-transaction-1790222122282-806d2201/report.json`.
  It covers private New Game, full and historical v2 Continue, stale source,
  cancellation and drain.
- `node tools/run-project-compile-smoke.mjs` passed with owned receipt
  `artifacts/node-tools/process-runs/godot-tMaZGU/watchdog.json`.
- `node tools/run-n3-private-main-load-headed.mjs` passed real-menu New Game,
  runtime Continue, and fresh-process Continue on the rebuilt Forward+
  GDExtension: `artifacts/native-world-backend/n3-private-main-headed-1790220968382-40c1a8d2/`.
  The New Game and Continue owned receipts are
  `artifacts/node-tools/process-runs/godot-Lednnn/watchdog.json` and
  `artifacts/node-tools/process-runs/godot-qumBXi/watchdog.json`.
- `node tools/run-n3-private-main-load-headed.mjs --historical-from <that
  fixture directory>` passed fresh-process historical terrain-only v2
  Continue in
  `artifacts/native-world-backend/n3-private-main-headed-1790221337658-6f71a146/historical_continue-report.json`,
  with owned receipt `artifacts/node-tools/process-runs/godot-HnpPHC/watchdog.json`.

This is a focused service diagnostic, not headed frame-cadence evidence. The
largest 256-record admission call ranged from 4.3 to 6.3 ms across the
full-limit runs, and one exceeded the shared 6 ms gameplay publication
envelope. Stage A executes under visible loading; later production admission
needs its own measured budget.
The decoded save snapshot currently has cooperative borrowed ownership;
`snapshot_override` may retain writable aliases. A later stage must establish
exclusive value ownership and bounded disposal, or a streaming save reader,
before claiming a responsive maximum-size load and teardown. Worker completion
latency and total headed frame cadence remain unproved.
The private retirement API is for this staged candidate only. It does not
establish native terrain, collision, navigation or save authority. Final
Gate 5 remains open.
