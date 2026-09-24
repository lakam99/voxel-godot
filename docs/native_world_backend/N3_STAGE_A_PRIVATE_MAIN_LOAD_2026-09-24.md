# N3 Stage A: private Main native load candidate

Status: production Main loading integration checkpoint. N3 terrain and
collision authority cutover remains incomplete.

Main now retains one private `NativePrivateMainLoadStage` through initial New
Game, file-backed Continue, and runtime Continue. It resolves historical v2
`terrain`-only saves through the bounded legacy converter, then admits the
canonical v2 volume through `NativeTerrainLoadTransaction` at no more than 256
records per advance. The candidate commits against its native source identity
and remains privately held until the next load or graceful quit drains it.
Loading progress is visible before gameplay readiness. No gameplay query,
terrain block, collider, navigation source, or save snapshot uses this private
backend; GDScript generation and Voxel Tools collision remain authoritative.
Before commit and after the ready loading yield, Main reconstructs the small
current source descriptor and rejects a changed seed/town policy. The focused
contract changes the seed during private preparation and verifies rejection
and drain.

The real save-v2 JSON boundary exposed two mismatches. Godot decodes numeric
JSON fields as floats. The snapshot lease and import transaction now accept
only finite, nonnegative, exact whole-number revisions within the native
2^53 range. The historical column converter likewise accepts exact int32
coordinates represented as either integers or whole-number floats. Fractional
and out-of-range values still fail closed. The converter retains the decoded
save without a deep setup copy and checks later columns on admission.

Focused contracts:

- `node tools/run-n3-native-world-source-request.mjs`:
  `artifacts/native-world-backend/n3-world-source-request-1790218753670-2d4e9a09/report.json`
  passed, including JSON-decoded lease and numeric boundaries.
- `node tools/run-n3-main-terrain-load-transaction.mjs`:
  `artifacts/native-world-backend/n3-main-load-transaction-1790218760820-d69222e8/report.json`
  passed, including decoded v2 import and commit. Its 600-record fixture admitted
  128 records per advance and reported a 1,988-microsecond maximum advance.
- `node tools/run-n3-legacy-terrain-load-transaction.mjs`:
  `artifacts/native-world-backend/n3-legacy-terrain-load-transaction-1790219383423-2041dc40/report.json`
  passed, including JSON-decoded historical conversion, exact script restore
  parity, private New Game/full-v2/historical-v2 candidates and cancellation.

Headed Forward+ Main evidence, Godot 4.6.1, seed `n3-private-main-headed`:

- New Game through the real menu and runtime v2 reload passed in
  `artifacts/native-world-backend/n3-private-main-headed-1790219402155-9144bc42/new_game-report.json`.
  The private candidate was observed pending and ready before gameplay
  readiness; the report includes loading captures. Owned process receipt:
  `artifacts/node-tools/process-runs/godot-UJaBn8/watchdog.json`.
- Fresh-process file-backed Continue passed in
  `artifacts/native-world-backend/n3-private-main-headed-1790219402155-9144bc42/continue-report.json`.
  Its visible pending capture is `private-pending-continue.png` in that same
  directory. Owned process receipt:
  `artifacts/node-tools/process-runs/godot-FeTpie/watchdog.json`.
- Fresh-process historical v2 `terrain`-only Continue passed in
  `artifacts/native-world-backend/n3-private-main-headed-1790219840356-933e3d14/historical_continue-report.json`.
  The private transaction admitted 20 converted durable records and gameplay
  and save restore readiness were both `ready`. Its visible pending capture
  is `private-pending-historical_continue.png` in that directory. Owned
  process receipt: `artifacts/node-tools/process-runs/godot-Ot1lRD/watchdog.json`.

Each passing headed run exited naturally with authoritative zero-member Job
Object proof. The historical test fixture starts from an isolated save copy,
removes `terrainVolume`, and supplies one legacy excavation column. The
headless menu smoke is unsuitable for this visual path on the current Godot
renderer: its dummy renderer emitted RID errors and the log watcher stopped
the owned process. Those failed receipts remain under `artifacts/node-tools`.

These reports prove only the private Main loading candidate and the existing
script-backed gameplay readiness. They do not prove a native gameplay query or
physical publication, actor admission on native collision, save export from
native deltas, frame cadence across the whole load, or final Gate 5. The
private backend now uses acknowledged worker retirement after a maximum-size
release diagnostic found an 8–11 ms Main-thread destructor. The focused fix
and its limits are in `N3_PRIVATE_MAX_SAVE_RETIREMENT_2026-09-24.md`.
The snapshot lease is cooperative:
`snapshot_override` callers can still hold writable nested aliases and must
not mutate them during import. The private stage therefore cannot be promoted
to save or gameplay authority without a stronger owner boundary. N3 Stages
B-E and the original final acceptance remain open. The current branch also
needs synchronization with later N3/N5 owner API commits before downstream
cutover work and frozen final evidence.
