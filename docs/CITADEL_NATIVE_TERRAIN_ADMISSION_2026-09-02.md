# Citadel native terrain admission

## Review boundary

Branch `codex/citadel-visuals-clean`, parent `8ec5266`; existing uncommitted
integration work was preserved. This report covers source admission, native
viewer gating and ordinary-runtime wiring. Independent critic Bernoulli approved
this focused commit after the final 124/52/42/27/28 controls and evidence review.
It does not claim a spawned city, complete checkpoint 2/3, or headed readiness.

The preserved source, candidate field and terrain profile remain the authorities.
StructureSystem owns a composed CitadelTerrainAdmission service. It dispatches
the existing owned Site queue, accepts only matching generation/token/source
receipts, and retains pending requests under queue pressure. Invalid generated
sites fail explicitly; they are not silently omitted. A completed source profile
is appended to a seed-bound immutable holder before affected native loading.
Each native block captures one holder snapshot; old clones remain unchanged.
WGS refreshes its derived caches, not durable edited cells, on profile additions
and holder replacement (including equal-count replacements).

Town inputs are finalized once at native generation construction, not at early
StructureSystem setup. The existing queue canonicalizer supplies the same frozen
terrain-relevant town records to source jobs and the native context. Ordinary
cache growth does not reset this generation. In-game New Game now invokes the
existing staged terrain initializer through an optional awaited tutorial staging
callback, after the scenario reserves its town layout and before construction.
Failure stops startup; no town-radius rule is copied into Main. Deferred initial
boot and Continue already reserve the scenario layout before native creation.
Both native physics publication and Main's active-runtime test reject stale
generation contexts, including the interval before an awaited reset.
Unfinalized admission rejects all source/bounds requests, including candidate-free
bounds, without mutating caches or demands; dispatch is disabled until finalization.

Native viewers remain off-tree until their conservative footprint is admitted.
The footprint covers the capped view distance plus two maximum mesh blocks.
Moving or expanding a viewer retains its last admitted state while pending;
auxiliary requests remain retryable. Foreign native viewers stop automatic
loading synchronously. Source generations are isolated through the existing
native reset/drain contract; equal seed text alone does not establish identity.
The installed extension, not just documentation, is exercised by the native test.

Gameplay chunk requests remain queued until their source is ready. Initial boot
initializes the existing terrain authority before admission, then starts the
existing chunk/collision readiness clocks. Source preparation has its own
450-second per-worker ceiling, matching the existing source watchdog; this is
not a claim that multi-minute preparation is acceptable streaming latency.
The player uses its unchanged terrain-motion proof and shared motor. Pending or
failed admission rejects movement/dodge; source readiness still requires actual
native collision publication. Message emission uses the ordinary action-message
API. Visible HUD behavior remains unverified.

Only reconstructible geometry is evicted at the 16-source cache limit; admitted
terrain profiles remain. Rebuilds must match the previous source key/signature,
level, envelope and apron. A prepared-to-absent contradiction fails explicitly
without erasing the admitted profile. Retired source payloads use the queue's
owned disposal worker. Native and source workers are drained during shutdown.
No protected NPC routing, motor, door authority or save format was changed.
TutorialSystem's sole change is the optional staging callback; NPC behavior is
unchanged. Its loading plan was reread to preserve readiness/failure ordering.

## Evidence and reproduction

All artifact paths below are under `artifacts/citadel-runtime-integration/`.
Each run has `report.json`, `stdout.log`, `stderr.log`, and `watchdog.json` unless
specified otherwise. Wrappers require fresh output directories and record source
hashes. No screenshots are claimed for these headless source/service controls.

| Run | Result | What it proves / does not prove |
| --- | --- | --- |
| `terrain-admission-contract-06` | 124/124 | Synthetic queue/receipt tests: unfinalized-input rejection, retention, stale isolation, immutable stores, source-cache eviction/reconstruction, prepared-to-absent rejection and shutdown disposal. Not full real-source or scene execution. |
| `profile-snapshot-contract-04` | 27/27 | Actual frozen Site profile through real WGS, context clones and native block generation; density/material agreement, edits retained, old clones stable, equal-count replacement. No actual Site rebuild or live terrain mesh. |
| `native-admission-13` | 42/42 | Installed native terrain/viewers, queued reset, wrong-seed rejection, auxiliary admission and real player/motor/defense against a synthetic collision plane. No Main/New Game, real citadel geometry, visible HUD or visual acceptance. |
| `terrain-bootstrap-02` | 28/28 | Actual MainCore orchestration around synthetic dependencies: initialization/reset precede admission, failure prevents chunk publication. Not a real game boot. |
| `town-inputs-03` | 52/52 | Actual tutorial start/reserve/restore, real admission and native generation-context construction with synthetic downstream dependencies. Final radius reaches both consumers; callback failure stops construction; explicit empty snapshot stays empty. Not full Main/New Game/Continue gameplay. |
| `terrain-admission-profile-01` | 33/33 | Existing building terrain-profile service contract. Not live traversal. |
| `terrain-admission-queue-01` | Passed | Existing Site queue contract, including owned retirement; measured maximum poll 264 microseconds. Not a runtime frame ceiling. |
| `terrain-admission-main-parse-04` | Clean | Main.gd dependency parse after startup initialization and scenario ordering fixes. Parse only; no gameplay. |

Commands from the project root (choose new output paths when repeating):

```powershell
./tools/run-citadel-terrain-admission-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/terrain-admission-contract-06
./tools/run-citadel-profile-snapshot-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/profile-snapshot-contract-04
./tools/run-citadel-native-admission-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/native-admission-13
./tools/run-citadel-terrain-bootstrap-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/terrain-bootstrap-02
./tools/run-citadel-town-inputs-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/town-inputs-03
./tools/run-citadel-site-build-queue-contract.ps1 -OutputDirectory artifacts/citadel-runtime-integration/terrain-admission-queue-01
```

The profile input is `actual-site-source-05/result.bin`, SHA256
`7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf`:
world seed `atlas-1492`, region `(1,-3)`, recipe seed `1298433643`, scale `1.25`.
The equal-count replacement uses a clearly labeled derived test profile two
cells higher. It is not an authored runtime repair or a second accepted citadel.

Native-13 records the installed extension DLL plus runtime, generator-context,
player, survival, defense and shared motor hashes. The generator is deliberately
substituted with recording/synthetic density inputs. A two-millisecond delay
creates queued native work for reset testing; it is not performance evidence.
The collision phase disables visuals before attaching the viewer and leaves
collision enabled. The real player's act never writes its position directly.
Controls prove rejected dodge spends no stamina, accepted dodge moves through
physics, and injected source failure stops an already-active dodge.

For the Main parse and existing terrain-profile runner, exact argument vectors
are recorded in their watchdog summaries. Both use the existing process-owning
watchdog, headless `--script`, and a 45-second cap; Main adds `--check-only`,
and the profile runner sets `VOXEL_BUILDING_TERRAIN_REPORT` to its report path.
Selected successful runs exited naturally with zero owned processes and no
engine warnings/errors. No process is inferred dead merely from a missing UI.

## Failures retained, not relabeled

- `profile-snapshot-contract-02`: four genuine equal-count holder-rebind
  failures. Fixed by refreshing when holder identity changes; final 03 passes.
- Native-02 and intermediate Main parse runs: GDScript return-path and inherited
  member-resolution errors. Fixed; final Main parse is clean.
- Native-06: test setup accessed an off-tree transform. Fixed by attaching the
  player with physics disabled before runtime setup.
- Native-07: 33 assertions passed but the runner **failed** with dummy-renderer
  RID/mesh errors. Native-08 was an unchanged clean rerun, not proof of a fix.
  Subsequent player controls are explicitly collision-only. Rendering remains
  unverified and these errors are not declared resolved by turning visuals off.
- The first manually launched NPC contract lacked the required run-token
  environment field and failed freshness checks. The corrected contract-02
  supplies it and passes. No production NPC change was made.

## Protected NPC baseline comparison

The same `atlas-1492` seed, `both` time mode and existing NpcAutonomyTest scene
were rerun via the owned watchdog (headless, fixed 60 FPS, 45-second cap).
The explicit user exception in `CITADEL_RUNTIME_INTEGRATION.md` still applies.

| Artifact run | Results | Engine error headers | Baseline comparison |
| --- | --- | --- | --- |
| `terrain-admission-final-npc-contract-01` | 84/84 | 0 | Matches baseline |
| `terrain-admission-final-npc-motor-01` | 48/48 | 4 | Same headers as baseline, not error-free |
| `terrain-admission-final-npc-nav_world-01` | 84/84 | 4 | Same headers as baseline, not error-free |
| `terrain-admission-final-npc-route-01` | 130/132 | 244 | Same two detour failures and same error headers |

The two failures are `npc_route_diagnostic_home_collision_lattice_exact_detour`
in the two modes. Route exits 1; the others exit 0. All four watchdogs prove
clean shutdown and zero owned processes. Error-header comparison against
`baseline-2026-09-02/{suite}-both/stderr.log` has zero differences. These are
focused regression observations, not a clean NPC release or live acceptance.
Reports retain their progress/trace/screenshot directory references; no headed
images were produced or claimed. Required environment was `VOXEL_PLAYTEST=1`,
test/NPC seed `atlas-1492`, NPC suite, time mode `both`, a fresh NPC run token,
report/progress/trace/screenshot paths and watchdog seconds `45`.

## Still required for the goal

Publish the preserved buildings/furniture through existing publishers, shared
trees and shared player doors; measure and bound publication work; unload and
reconstruct symmetrically. Then obtain critic permission for ordinary Main menu
to New Game, continuous player approach and gate traversal, visual inspection,
departure/re-entry, durable-edit save/Continue and runtime performance evidence.
The full cold source still takes minutes. None of these narrow controls makes
that latency acceptable or proves a visible city exists in ordinary play.
