# Physical navigation crossings and regional candidate snapshot

Worktree: `voxel-biome-world-godot-citadel-visuals`, branch
`codex/world-streaming-architecture`, parent `d6314ed`.

## Verified interface milestone

`NavigationBakeDescriptor` carries source polygons and physical crossing records.
Polygon vertices contribute to descriptor bounds, including elevated/sloping
surfaces. Canonical identity includes crossings. `NavmeshWorldService` installs
physical crossings as actual NavigationServer links under the existing region
owner, without a door portal or action. Owner/geometry/identity validation happens
before replacement. Region retirement frees the links; door retirement preserves
unrelated physical crossings. Installation receipts check actual link geometry,
enabled state and directionality. Routing, motor and door execution are unchanged.

This interface does not certify source clearance, NPC movement, regional readiness
or performance. Its generated-source producer/adapter remains an uncommitted
candidate pending the findings below. No regional gameplay gate is promoted.

Commands run from this worktree:

```text
node tools/npc/run-npc-nav-world-tests.mjs -TimeMode Both -ReportPath artifacts/citadel-runtime-integration/regional-crossings-nav-06/report.json -ProgressPath artifacts/citadel-runtime-integration/regional-crossings-nav-06/progress.txt -TraceDir artifacts/citadel-runtime-integration/regional-crossings-nav-06/traces -ScreenshotDir artifacts/citadel-runtime-integration/regional-crossings-nav-06/screenshots -WatchdogSeconds 120
node tools/run-building-contract.mjs -Contract DoorNavigationRetirementContract.gd -ReportEnvironment DOOR_NAVIGATION_RETIREMENT_OUTPUT -OutputDirectory artifacts/citadel-runtime-integration/regional-crossings-door-retirement-02 -TimeoutSeconds 120
```

Navigation: 86 cases / 186 assertions pass, including all original 84 cases.
The new synthetic two-platform case queries the real server across a physical
link, verifies no door actions, checks disabled-link rejection, rejects an invalid
owner replacement while retaining the previous owner, and verifies retirement.
Door lifecycle: 135 checks pass. Both final runs have clean logs and owned cleanup.
These are service/contract evidence, not live NPC movement acceptance.

Broad headed regression:

```text
node tools/run-playtest.mjs -Visible -Seed atlas-338921745 -ReportPath artifacts/citadel-runtime-integration/regional-crossings-broad-01/report.json -ProgressPath artifacts/citadel-runtime-integration/regional-crossings-broad-01/progress.txt -ScreenshotPath artifacts/citadel-runtime-integration/regional-crossings-broad-01/playtest.png -TimeoutSeconds 600
```

Finished 160/163; natural exit 1, clean logs/cleanup, zero owned processes
(`artifacts/node-tools/process-runs/godot-y3VFCW/watchdog.json`). Save/reload,
town/NPC broad checks, structure checks and interaction checks passed. The known
`character_asset_pack_ready` failure remains (40 assets / 11 families). Two further
failures, `generated_environment_prop_visuals` and
`generated_environment_prop_authority_and_static_fallback`, report procedural trees
still building at the fixture's 720-frame limit. Their baseline attribution is
unresolved; they block full-candidate promotion. Do not relabel this run green or
increase the fixture deadline without determining the production cause. The report
records the requested seed above, but the broad fixture's own debug trace also
reports atlas-1492; it does not establish fresh-seed ordinary gameplay acceptance.
The final viewport capture was inspected. This broad fixture is integration
coverage, not a substitute for real NPC crossing or five-minute traversal evidence.

Final nav suite ownership receipt: `artifacts/node-tools/process-runs/godot-Bga0oC/watchdog.json`.
Both the descriptor interface milestone and the uncommitted source candidate were
present during the broad run; no isolated broad promotion claim is made for either.

Intermediate failures are retained: adapter variable shadowing prevented parsing
in nav-02; nav-03 exposed the existing dispatcher's lack of awaiting async cases;
nav-04's new fixture queried before asynchronous endpoint ownership was ready.
The fixture now waits for a positive map iteration and actual endpoint owners,
bounded by two seconds. Nav-05 caught the unguarded pre-iteration query warning;
nav-06 guards it. Existing 84 cases remained green when they ran to completion.
Door-retirement-01 incorrectly supplied a directory to a file-valued environment
variable and exited 2; the corrected invocation above passes without code changes.

## Full headed candidate before further source fixes

```text
node tools/run-citadel-candidate-teleport-playtest.mjs -Seed atlas-3376622889 -CandidateRegion "-2,-2" -SpawnCell "-3334,-2666" -SkipTutorial -ForceDaytime -ForceClearWeather -Resolution 1920x1080 -StartupTimeoutSeconds 180 -TimeoutSeconds 600 -OutputDirectory artifacts/citadel-runtime-integration/candidate-teleport-regional-nav-01
```

Actual initial spawn, zero setup relocations; ordinary production `Main.tscn`
startup with diagnostic title bypass and the listed gameplay flags. Startup
85.545s; complete diagnostic 165.221s. Natural exit 0, no engine warnings/errors,
unchanged frozen sources, clean cleanup and zero remaining owned processes.
`verification.json`, `watchdog.json`, `report.json` and captures share that folder.
This is not ordinary menu/traversal or NPC acceptance, nor an empty-cache claim.

`initial_spawn_ready.png` shows continuous rendered nearby terrain. The prior
`d6314ed` loading gate still requires collision readiness plus a post-draw receipt
before releasing control. Citadel completion is tracked separately. The exact
accepted-source SHA-256 is unchanged from the prior headed candidate:
`dbe543f28dfe876f28ae8611d7e869f07975f69e09067b2fe5c88d56e3e4b042`.

Inspected courtyard, doorway and stair-exit captures. The citadel is present,
but courtyard haze and very dark/obstructed close views prevent complete visual
acceptance. In particular `castle_gatehouse_wall_stair_exit_00.png` is filled by
a surface; it does not prove a usable stair exit. No new visual-quality pass is
claimed. Scene-ready still reports the existing `door_activation_pending`
placeholder, not genuine whole-site gameplay readiness.

## Independently detectable blockers from this snapshot

- All 12 stair declarations fail source endpoint certification. Recorded blockers
  include landing/exit bearing piers, the gatehouse roof deck, keep storey trim and
  the first keep stair shoe. These are constraints reported by the existing source
  clearance authority, not failures in the synthetic two-platform test. They block
  promoting this regional navigation candidate; live collision-backed movement is
  still required to establish the player/NPC effect and validate a source repair.
- Fourteen of 20 source door portals are unresolved. Several require terrain-side
  support composition; a source-only support failure is not proof of a terrain
  hole. Other declarations report embedded endpoints. Preserve exact registered
  door identity and resolve cross-tile ownership instead of inventing door links.
- Worker compilation emits 158,876 polygons across 42 navigation tiles from
  154,148 samples, taking 10.404s (11.639s total dependency preparation). Main-thread
  upload/signature costs for this volume are not yet bounded or accepted.
- Scene publication still reaches 30.825ms atomic work against the 4ms budget.
  The candidate does not address the already recorded traversal pacing failure.

`navigation-source.json` retains all source certifications and supports from the
accepted binary. `inspect-source.gd` in the same artifact folder only restores that
snapshot and calls the existing manifest builder at the recorded origin; its
watchdog/logs are prefixed `source-inspect-`. It does not regenerate the world or
alter production. The earlier archived source contract (`regional-nav-preparation-01`,
107 checks) used a different old source and is not evidence about current stairs.

Before promoting the producer/adapter: resolve the source/terrain dependencies;
preserve actual door ownership across tiles; replace provisional unbounded prop
height filtering with measured collision facts; bound polygon upload/signature
costs; retain source revisions and retryable demands; then verify genuine regional
acknowledgements and real NPC/player crossings. Whole-scene readiness currently
still gates access to these artifacts. Continue's headed presentation verification,
five-minute traversal and full cold/warm acceptance campaign remain outstanding.
