# Shared stair source clearance milestone

Branch `codex/world-streaming-architecture`, parent `e748fd2`. This milestone
changes the shared castle switchback producer and its existing producer/physics
contract. The separate regional navigation preparation/adapter candidate remains
uncommitted and unpromoted; all full-runtime results below include that candidate.

Both keep and gatehouse stairs now have a finished, supported base landing.
Carriages declare their actual start/end landing sources. The flights leave more
clearance beneath enclosing trim, with their asymmetric housed-ramp envelope
centred in the opening. Bearing piers move outward with matching underframe widths
and physical seat declarations. No route, motor or door execution changes.

## Verification

```text
node tools/run-building-contract.mjs -Contract CitadelStairClearanceContract.gd -ReportEnvironment CITADEL_STAIR_REPORT -OutputDirectory artifacts/citadel-runtime-integration/stair-regional-clearance-03 -TimeoutSeconds 120
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-stair-regional-01
node tools/npc/run-npc-nav-world-tests.mjs -TimeMode Both -ReportPath artifacts/citadel-runtime-integration/stair-regional-nav-01/report.json -ProgressPath artifacts/citadel-runtime-integration/stair-regional-nav-01/progress.txt -TraceDir artifacts/citadel-runtime-integration/stair-regional-nav-01/traces -ScreenshotDir artifacts/citadel-runtime-integration/stair-regional-nav-01/screenshots -WatchdogSeconds 120
node tools/run-playtest.mjs -Visible -Seed atlas-338921745 -ReportPath artifacts/citadel-runtime-integration/stair-regional-broad-01/report.json -ProgressPath artifacts/citadel-runtime-integration/stair-regional-broad-01/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/stair-regional-broad-01/playtest.png -TimeoutSeconds 600
```

- Existing stair producer/physics contract: 51 checks pass, including real
  published collider correspondence, capsule clearance at landings and physical
  integrity negative controls. The added source endpoint checks pass. This is
  contract evidence, not live player/NPC stair traversal. Its composed fixture
  retains its existing pinned older recipe; the full candidate below covers the
  current accepted source separately.
- Full headed production diagnostic: natural exit 0, clean engine logs, unchanged
  launch-frozen sources, cleanup passed and zero owned processes. Initial spawn
  is the requested target, with zero setup relocations. Startup 84.369s; entire
  diagnostic including captures 144.461s. These are fresh-process observations
  with existing dependency caches, not cold-load performance acceptance.
- Current source has 12 vertical links and zero unresolved stair endpoint
  certifications, previously twelve unresolved. It has 4,557 parts, 178 furniture
  bodies, 20 registered doors and four completed trees. Existing source binding
  and collision correspondence audits report no mismatches. Source certification
  does not establish live movement or regional navigation acknowledgement.
- Navigation world suite: 86 cases pass. Watchdog
  `artifacts/node-tools/process-runs/godot-Y4iCtM/watchdog.json` records natural
  exit 0, cleanup passed and owned zero. This is service/contract coverage.
- Headed broad suite: 160/163, with exactly the same three failed names and
  details as the independent `d6314ed` reference checkout documented in
  `WORLD_STREAMING_PHYSICAL_CROSSINGS_2026-09-11.md`. They are
  `generated_environment_prop_visuals`,
  `generated_environment_prop_authority_and_static_fallback` and
  `character_asset_pack_ready`. The fixture internally uses `atlas-1492` despite
  the runner seed. Watchdog `artifacts/node-tools/process-runs/godot-hsiOPT/watchdog.json`
  records natural exit 1, no forced cleanup and owned zero. These existing
  presentation failures remain open; the suite is not green.

Inspected the headed initial spawn and courtyard captures: nearby terrain is
continuous when control is released, and the citadel is visibly present after
scene publication. The gatehouse landing capture shows treads, walls and piers
but is too dark to prove traversal quality. Several existing diagnostic camera
placements intersect or face enclosing walls. No live stair-access acceptance is
claimed. The broad screenshot retains the baseline partial tree presentation.

`candidate-teleport-stair-regional-01/source-change-scope.json` compares raw
accepted source fields against the previous headed candidate: two added base
landings, no removed parts, and all 190 geometry changes confined to the keep and
gatehouse stair assemblies. Thirty recipes change. Current accepted source SHA-256:
`9fa2b6782e6ef13f944460e932ca12a67c723d4c6578ea6e8b1f25dd63871372`.
This is a source-scope check, not complete rendered geometry parity.

The earlier focused attempts are preserved as `stair-regional-clearance-01/02`.
One exposed source endpoint blockers despite passing capsule samples; shortening
the flight further resolved source endpoints but failed existing real-physics
capsule checks. The final geometry resolves both without weakening those checks.

## Remaining production work

Fourteen of twenty source door portals still lack complete endpoint certification.
Some actual walking surfaces, including the raised lane and market plaza, lack
navigation declarations. Other doors have real clearance conflicts: notably the
gatehouse stair entrance beneath its first half-level landing, and a civic-house
door against a terrace mass. Fix each fact at its source; do not declare all
structural foundation tops walkable or treat missing support as automatically
being a terrain hole.

The diagnostic reports `scene_ready`, while `gameplayReady` remains false with
`door_activation_pending`. Zero unresolved stairs is not zero unresolved doors,
whole-site readiness, or completed regional streaming. Genuine owner/revision
acknowledgements, bounded publication, live collision-backed crossings, distance
tiers and the full cold/warm and five-minute traversal campaign remain open.

The nearby-terrain loading barrier is already committed in `d6314ed`. Real menu
New Game and Continue verification, including wall-clock timing and rendered
presentation ordering, is recorded in `WORLD_STREAMING_CONTINUE_2026-09-11.md`.
