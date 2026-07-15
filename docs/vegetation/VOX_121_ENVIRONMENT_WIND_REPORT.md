# VOX-121 Environment Wind Report

## Scope

VOX-121 adds the shared runtime wind field and shader contract required by the mature canopy assets from VOX-120. It deliberately does not publish those assets into procedural chunks; that integration belongs to VOX-122.

The implementation follows `CODEX_TUTORIAL_TOWN_NPC_LOADING_PLAN.md`: `EnvironmentWindSystem` is a composed presentation system created beside weather setup. It does not participate in tutorial-town generation, startup readiness, NPC registration, navigation publication, story commands, or generic NPC behavior. No `NpcPathing.gd` or `scripts/npc_ai/` file changed.

## Architecture

- `EnvironmentWindSystem` derives one deterministic, smoothly changing world wind field from seed, weather, cloud cover, precipitation, and the Phase 2 biome profile.
- Each update performs fixed O(1) work and exactly five global shader writes. It does not enumerate vegetation and never reads global shader values back from the render server.
- Tree and ground-detail shaders consume the same direction, strength, gust strength, gust frequency, and elapsed-time globals.
- Tree wind uses authored vertex color channels: red for main bend, green for leaf phase, and blue for detail flutter. Per-instance phase, stiffness, and biome response prevent synchronized motion without duplicating materials.
- Generated tree materials are cached by authored material role. The tested four-canopy fixture used the bounded maximum of eight shared tree materials.
- Wind displacement runs in the common vertex path, so visible geometry and directional-light shadow casting use the same deformed vertices. A 1.25 m tree cull margin covers the authored sway envelope.
- Grass, reeds, scrub, and leaf litter retain their existing response classes through `UV2.x`; pebble and snow detail remain static.

## Verification

### Focused contract

Command:

```powershell
.\tools\run-environment-wind-contract-tests.ps1
```

Report: `artifacts/vegetation/environment-wind-contract.json`

Result: 11/11 passed. Across 4,000 updates, CPU time averaged 3.61 microseconds, with p50 3 us, p95 4 us, p99 7 us, and max 27 us. The contract also proved deterministic smoothing, five writes per update, shared material reuse, distinct stable instance phases, the shader channel contract, static detail classes, and the tutorial/NPC integration firewall.

### Headed visual fixture

Command:

```powershell
.\tools\run-environment-wind-visual-playtest.ps1
```

Report: `artifacts/vegetation/environment-wind-visual.json`

Captures: `artifacts/vegetation/environment-wind-screenshots/`

Result: 8/8 passed on Godot 4.6.1 Forward+ with an NVIDIA GeForce RTX 5060 Ti. Calm-to-storm canopy change was 2.40%, motion between two storm instants was 2.70%, and the floor's moving shadow pattern changed by 2.87%. The rain/night/torch capture remained readable at 0.0606 average luminance. All four states held 72 draw calls, 24,484 primitives, and 72 rendered objects, demonstrating no per-frame object or material churn in the fixture.

This is a headed production-shader fixture using the actual VOX-120 GLBs and registry material/instance APIs. It proves visible deformation, asynchronous foliage, fixed roots, moving shadows, and night readability. It is not evidence that mature trees are already integrated into runtime biome chunks; that is VOX-122.

### Existing-system regressions

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\run-biome-environment-catalog-contract-tests.ps1 -ReportPath artifacts\vegetation\vox121-biome-catalog-regression.json
```

Compile smoke passed for the main menu and main scene. The biome catalog regression passed 12/12, including unchanged placement/weather values and zero placement RNG consumption.

The representative normal-runtime pass used:

```powershell
.\tools\run-normal-runtime-performance-pass.ps1 -DurationSeconds 45 -WarmupFrames 120 -Resolution 1280x720 -ReportPath artifacts\performance\vox121-normal-runtime.json -ProgressPath artifacts\performance\vox121-normal-runtime-progress.txt -LogPath artifacts\performance\vox121-normal-runtime-godot.log -ScreenshotPath artifacts\performance\vox121-normal-runtime.png
```

It traversed 453.39 m and created 98 chunks. Frame p50/p95/p99/max were 11.13/21.83/28.29/29.85 ms. The runner failed only its 22 ms p99 aggregate threshold. Wind did not appear among the 20 slowest sections; peaks were hostiles, projectiles, HUD, and chunk prop spawning. The focused wind update remained 7 us at p99, so this broad failure is recorded as non-wind evidence rather than concealed or used to tune unrelated systems.

### World signature audit

Two current VOX-121 signature runs were byte-identical to one another. Both differed from the tracked baseline only in the `props` collection: all terrain samples, generated blocks, generated-tier counts, loaded chunks, structure counts, town home records, and seed were exact matches. Current output consistently held 4 sampled props versus 32 in the dated baseline. No VOX-121 change touches prop placement, ecological density, prop RNG, town generation, or structure generation, and the Phase 2 catalog regression independently proves placement parity and zero RNG consumption.

The baseline was not updated. VOX-122 must explicitly review this already-existing prop-signature drift while integrating mature canopy visuals, rather than laundering it into a visual-only signature change.

## Outcome

The shared GPU wind foundation is complete and bounded. Runtime biome publication remains intentionally deferred to VOX-122, where canopy coverage, physical trunk coherence, authored-world exclusions, harvesting, saves, and real tutorial-town/NPC evidence can be evaluated together under the loading-plan boundary.
