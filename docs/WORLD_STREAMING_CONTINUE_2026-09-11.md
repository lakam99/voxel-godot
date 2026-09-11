# Headed New Game and Continue loading verification

Worktree: `voxel-biome-world-godot-citadel-visuals`; branch
`codex/world-streaming-architecture`; parent `12fdb78`.

The existing two-process tutorial runner now exits through
`Main.request_graceful_quit`, as the normal runtime and full tutorial runners do.
Its former private teardown stopped terrain then freed Main, bypassing navigation
retirement. Gameplay setup, input, assertions, deadlines and watchdog error checks
are unchanged. No route, motor or door execution code is changed.

```text
node tools/npc/run-tutorial-save-continue-playtest.mjs --visible --timeout-seconds 360 --stale-progress-seconds 90
```

Final evidence: `artifacts/npc/node-production-runs/save-continue-NvpVyR/`:
`report.json`, `report-proof.json`, both stage reports and screenshot directories.
Random seed selected through New Game: `atlas-98135749`. The real menu receives
mouse input for New Game and Continue in separate headed processes, with an
isolated real SaveSystem namespace. No gameplay-affecting flags or fixed frame
pacing override; this runner uses 1280x720, not performance acceptance at 1080p.
Its required forbidden-call static guard passed.

Both stages pass and exit naturally with no engine warnings/errors. Watchdogs:
`artifacts/node-tools/process-runs/godot-6sVNwD/watchdog.json` (New Game) and
`artifacts/node-tools/process-runs/godot-IgnIK3/watchdog.json` (Continue), each with
cleanup passed, no forced cleanup and authoritative zero remaining owned members.

In both stage timelines, `Drawing nearby terrain` precedes `Nearby terrain
displayed`, which precedes `Gameplay prerequisites ready` and the unlocked main
scene. The production presentation owner emits `Nearby terrain displayed` only
after a post-draw callback with the same ready terrain/mesh revision. Inspected
Continue's menu and first restored player view, plus the final observer view.
The first player view faces the closed starter door; it does not prove an outdoor
panorama. The observer view shows Mira inside the restored home with floor, walls,
furniture and closed doors visible. This combines a real rendered runtime with
the production readiness sequence, not a synthetic readiness flag.

Wall-clock timing from `phase0Timing.wallElapsedMsec`:

- New Game click 137ms; startup complete 40,841ms: **40.704s**.
- Continue click 128ms; first observation after loading 34,850ms: **34.722s**.
  The latter includes brief fixture readiness setup after loading, so is an upper
  bound on click-to-unlock rather than an exact unlock timestamp.

Do not use the loading-step `time` values (23.4s and 15.4s) as load duration: those
accumulate game-frame deltas and undercount wall-clock stalls. These are two fresh
processes using existing dependency caches, not an empty generated-cache campaign
or a known-citadel-seed comparison.

The live New Game stage approaches the door by input, opens it and acknowledges
dialogue, then persists the generic go-home intent. Continue restores that intent;
Mira subsequently moves, opens her home door and reaches a strict home location.
The final observer capture shows the door closed. The trace records home-door
opening, closure and settled interior arrival. At the first Continue observation
Mira is already 20.434m from the player porch; the reported 0.575s porch-clearance
delay is therefore not evidence of a fresh porch departure after Continue.
This is existing live integration coverage, not full citadel crossings or
five-minute streaming/visual acceptance.

The earlier attempt in `save-continue-xborLx` (seed `atlas-56759348`) successfully
created its save but failed shutdown with leaked objects and seven resources in
use. The watchdog stopped the owned job on the engine error and proved zero;
cleanup did not pass. Continue was never launched. Preserve this failure rather
than treating its successful gameplay report as a passed two-process run.

Regional source publication, citadel stair/door dependencies, bounded upload,
distance tiers/occlusion, terrain LOD and the full acceptance campaign remain open.
