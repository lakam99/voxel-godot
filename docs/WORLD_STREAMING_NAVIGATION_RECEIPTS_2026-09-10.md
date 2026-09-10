# Navigation publication receipts

Branch: `codex/world-streaming-architecture`, after `4ec71a1`.

The existing navigation publisher now records which authoritative surface IDs
actually contributed valid polygons, and which declared links it installed.
Receipts bind the source key, canonical descriptor, owner RID and installation
serial. Readiness rejects stale revisions, dirty/unloaded/replaced owners,
missing required geometry and unsynchronized engine installations. The existing
polygon construction and route stack remain unchanged. Receipts are discarded
with their owner; they are not saved world state.

Staged New Game/Continue now requires current receipts with complete declared
surface coverage for its existing initial NPC tile set. Pending installation is
retried while loading. Telemetry hashes the canonical descriptor signature to
avoid embedding complete geometry repeatedly in loading reports.

This is a prerequisite for regional readiness, not its completion: the initial
tile set is still NPC-derived and capped at 32. Receipts prove installation and
ownership, not endpoint clearance, seam connectivity, route validity or movement.
The 64m dependency closure and independent full-citadel completion remain pending.

## Verification

- Existing `StartupLoadingReadinessContractRunner.gd`, invoked with the Node
  owned-process watchdog: `artifacts/citadel-runtime-integration/regional-nav-startup-03/`.
  Nine contract checks pass, clean logs/exit/cleanup and zero owned processes.
- Existing `NavigationShutdownLifecycleContractRunner.gd`, same watchdog:
  `artifacts/citadel-runtime-integration/regional-nav-lifecycle-03/`.
  33 service checks pass, including actual server installation, source mutation,
  missing/duplicate surface IDs, link loss, replacement, unloading and shutdown.
  Earlier newly added fixtures assumed an engine acknowledgement after one frame;
  bounded waits on actual region iterations fixed the fixture assumption without
  weakening production readiness.
- `node tools/npc/run-npc-nav-world-tests.mjs -TimeMode Both -ReportPath artifacts/citadel-runtime-integration/regional-nav-world-02/report.json -ProgressPath artifacts/citadel-runtime-integration/regional-nav-world-02/progress.txt -TraceDir artifacts/citadel-runtime-integration/regional-nav-world-02/traces -ScreenshotDir artifacts/citadel-runtime-integration/regional-nav-world-02/captures`
  passes 84 cases / 178 assertions. The pre-existing synthetic generated-world
  fixture now attaches its fake main node before the real adapter reads global
  transforms. This fixes fixture setup errors, not gameplay or routing behavior.
  Watchdog `artifacts/node-tools/process-runs/godot-7Ym7eU/watchdog.json` proves
  natural exit, clean cleanup and zero owned processes. These are contract tests,
  not NPC gameplay acceptance.

## Headed production observation

`VOXEL_NORMAL_RUNTIME_PERF_SCREENSHOT` was set to the absolute `final.png` path
inside the following run directory, then:

```text
node tools/run-normal-runtime-performance-pass.mjs -Resolution 1920x1080 -DurationSeconds 75 -TimeoutSeconds 300 -ReportPath artifacts/citadel-runtime-integration/regional-nav-normal-01/report.json -ProgressPath artifacts/citadel-runtime-integration/regional-nav-normal-01/progress.txt
```

Random seed `atlas-85319906`, actual menu New Game, ordinary startup settings:
33.227s from input to current gameplay gate. All 17 initial navigation tiles had
current source receipts and complete declared surface coverage. The observer
then travelled 717.622m in 75 seconds, eight turns, 25 observed jumps and zero
terrain collision hold frames. Its existing godmode applies after startup.
The inspected capture is a dark rainy Plains view; it is not daylight geometry
or citadel verification. Output target was 1920x1080 (logical UI 1280x720).

**Performance failed.** Main script p99 9.943ms / max 52.962ms; worst section
`terrain_meshing_job_queue` 49.811ms inside a 51.331ms chunk update. Actual
post-draw traversal cadence p99 51.1ms / max 63.857ms, 562 intervals above 33ms
out of 4219. Rendering CPU p99 7.1ms / GPU p99 5.3ms. These are independent,
not frame-aligned measurements. Startup also contains a 9.468s draw interval.
This is not sustained 60 FPS, a five-minute acceptance run, a matched-seed
performance comparison, or the new 64m loading contract.

Watchdog `artifacts/node-tools/process-runs/godot-iG537c/watchdog.json`: natural
exit 1 for the performance failure, clean logs/cleanup, zero owned processes.
The final source adds only compact loading telemetry and the fixture attachment
after this headed run; final startup contracts exercise the telemetry change.

## Broad regression

```text
node tools/run-playtest.mjs -Seed atlas-1492 -ReportPath artifacts/citadel-runtime-integration/regional-nav-broad-01/report.json -ProgressPath artifacts/citadel-runtime-integration/regional-nav-broad-01/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/regional-nav-broad-01/final.png -TimeoutSeconds 600
```

Finished 161/163, matching the committed surface-worker replay: only
`character_asset_pack_ready` (40 assets / 11 families) and headless
`screenshot_saved` failed. Save/load and the tutorial home guard passed. The
known dummy-renderer null-texture error recurred; no navigation/mesh RID
initialization error was reported. This is a completed integration report with
baseline failures, not a green broad test.

Watchdog `artifacts/node-tools/process-runs/godot-RhiohP/watchdog.json` reports
exit 126, cleanup failure, and authoritative zero remaining owned processes.
As with the committed baseline, forced cleanup is a limitation, not a clean exit.
