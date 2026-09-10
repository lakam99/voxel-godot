# Native support-query integration

The production blueprint can now use BuildingSupportKernel for ordered physical
support queries during an owned resolution pass. GDScript still classifies parts,
selects candidate neighborhoods and validates the complete physical/root/dependency
report. Native records are private and discarded after resolution, cancellation or
invalidation. Base and the private memo implementation opt in by exact script;
custom implementations, unknown targets, unavailable extensions and extreme
numerical inputs retain the original path. Broken native protocol/configuration or
indices produce an explicit failure rather than a plausible empty support result.

Acceleration eligibility bounds finite position, size and rotation components to
1e12 to avoid float overflow in transformed geometry. This is not a new geometry
validity rule. An extreme-coordinate differential verifies the original report
and zero native queries. Existing memo ownership and exact source bindings remain.

## Build provenance

Both Windows x86_64 template_debug and template_release libraries were built with
the Node runner, API 4.6, clean godot-cpp revision
ba0edfed90512ec64aba51d4295a3e7e30112f86 and MSVC. Generated version.hpp identifies
4.6.0 stable; runtime is official Godot 4.6.1. The kernel protocol verifies
sizeof(real_t)==4. The existing host uses /O2; only the new kernel adds /fp:strict.
SConstruct pins dependency HEAD; clean dependency/generated-file provenance is
also a build-verification responsibility, not guaranteed by that HEAD check alone.

Installed DLL SHA256:

- Debug: 50e6004d539dff92f30e136f9a6298a32e4f3fda84dd522907015d8ee31e4571
- Release: fb02febd19cc41ad32f0b9a793ce67689cb0ce290d01152d4979e7abc14959ee

Release math was tested by temporarily mapping the debug extension entry to the
release DLL with no Godot processes running. The original mapping was restored
before source42. This is release-library parity, not exported-game acceptance.
Libraries and the dependency checkout remain ignored local build products; use
the Node commands in native/terrain_meshing/README.md to reproduce them. Windows
SCons discovery now prefers an executable or Python module over a .cmd wrapper
that failed to spawn with shell disabled. No PowerShell runner was added.

## Verification

All paths below are relative to this worktree. Focused and integration runs used
the owned watchdog and finished with clean logs, natural exit and owned zero.

- native-cache-01: existing validation-cache contract, 88 checks.
- native-cancellation-01: existing cancellation contract, 465 checks.
- native-support-contract-02 and native-support-release-contract-01: 18 checks
  each, covering ownership, nested cancellation, mutation/reorder/removal,
  private memo reuse, exact subclass fallback, extreme coordinates and explicit
  kernel failure. These are synthetic contracts, not live gameplay evidence.
- native-production-cost-01: frozen pre-native source41 full-proof differential,
  2.102386s to 1.075945s; release equivalent native-production-release-cost-01,
  2.120351s to 1.101881s. Both execute 75,741 native queries and preserve complete
  report and resolved snapshot bytes. Both have six passing checks.
- native-terrain-smoke-42: existing TerrainMeshingNativeSmokeRunner through
  building-runner phaseRun, including worker graph ownership and worker-pool
  fluid payload round trip. Passed. The building-contract CLI initially rejected
  this non-building script path before launch; no test result was inferred.
- tools/run-terrain-meshing-bounds-contract.mjs passed; report at
  artifacts/node-tools/run-terrain-meshing-bounds-contract.json.
- node --test tools/tests/node-runtime-migration.test.mjs
  tools/tests/legacy-workflow-ports.test.mjs: 29/29.

The named native-* evidence directories are under
artifacts/citadel-runtime-integration. Production commands:

```text
node tools/run-citadel-candidate-recipe-diagnostic.mjs -OutputDirectory artifacts/citadel-runtime-integration/candidate-recipe-42 -Seed atlas-3376622889 -CandidateRegion "-2,-2" -ExpectedRecipeSeed 1393179273 -ExpectReady
node tools/run-citadel-candidate-integration-continuation.mjs -SourceDirectory artifacts/citadel-runtime-integration/candidate-recipe-42 -OutputDirectory artifacts/citadel-runtime-integration/candidate-continuation-42
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SkipTutorial -ForceDaytime -ForceClearWeather -StartupTimeoutSeconds 120 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-42-01
node tools/run-playtest.mjs -ReportPath artifacts/citadel-runtime-integration/native-support-runtime-42/playtest-report.json -ProgressPath artifacts/citadel-runtime-integration/native-support-runtime-42/playtest-progress.txt
```

Source42 preparation took 62.199s versus source41 75.458s; independent physical
validation took 1.160s. CitadelSourceValueDiff with CITADEL_SOURCE_DIFF_OTHER=42
reported only civicClearance/elapsedUsec changed in source-diff-27-42. Continuation
passed 26 checks. Headed42-01 passed 24 checks. Timing from launch:

| Observation | Seconds |
|---|---:|
| Initial startup complete / discovery begins | 19.101 |
| Source accepted | 93.186 |
| Scene publication pending | 95.200 |
| Scene publishing | 105.218 |
| First sampled scene-ready | 148.404 |
| Ordinary input approach | 149.403 |
| Terminal observation | 166.443 |

The prior first scene-ready was 157.130s: this sample improved by 8.726s.
Accepted-source SHA256 remains
1f07667654652dbb53a4fb6107352d8fd1186ff79594b96563562f14ff5032f7.
All 3,253 expected source colliders were published. ready.png,
courtyard_overview.png, urban_row_00_left_door.png and
castle_keep_stair_exit_00.png were inspected: the citadel, terrain and trees are
visible; the door approach is clear and the stair has a landing. Heavy grain in
shadows and dark close views remain. This does not prove every doorway, interior,
furniture interaction or NPC route. Separate gameplayReady=false and the hardcoded
door_activation_pending label remain unchanged reported status, not a verified
diagnosis of pending door activation. Scene-ready must not be relabeled as complete
gameplay readiness.

Publication spent 11.885s inside 2,866 advances and 31.037s between them; the
latter includes other frame work, not merely idle time. Maximum atomic publication
work was 28.112ms, exceeding the cooperative 4ms slice. The ready observation's
434 performance samples recorded max 9.365ms, p99 7.778ms, no recorded last spike;
top section maxima were chunk 5.808ms, autosave JSON/write 4.158ms and terrain
job queue 3.811ms. This observation window does not establish hitch-free loading.
The runner includes ordinary sprint input after setup teleports, not continuous
travel from initial spawn or a complete normal-runtime performance acceptance.

The mandatory atlas-1492 broad run reached finished=true, 160/163 passing.
Failures: tutorial_npc_home_and_guard_behavior, character_asset_pack_ready
(40 assets/11 families versus the older expectation), and screenshot_saved.
These match the recorded column-runtime-39/worker-allocation baselines. Dummy
texture null errors at PlaytestRunner.save_optional_screenshot triggered forced
cleanup: artifacts/node-tools/process-runs/godot-rjdaX8/watchdog.json records
cleanupPassed=false, authoritativeZeroProven=true, final membership empty.
This is a failed broad run, not a clean pass; the baseline defects remain open.

The 90-second usable-arrival target remains unmet. Repeated clearance work and
publication costs remain measured opportunities; no safeguards or geometry were
removed to obtain this gain.
