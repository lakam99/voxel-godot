# Citadel Life Handoff — VOX-217 through VOX-222

## Purpose and current branch

This is a pause-state handoff for the Citadel Life work. It is written for the
next agent to continue from the current working tree without recreating the
same diagnosis.

- Branch: `codex/vox-209-npc-biped-blueprint-poc`
- Working tree: scoped Citadel Life, building-navigation, terrain-site,
  furnishing-access, and runner work is intentionally uncommitted until the
  commit that accompanies this document.
- Main active blocker: `VOX-224` (layered building support/stair navigation)
  blocks `VOX-218`; the current Citadel Life run is not an acceptance pass.
- Do not discard or reset this work. Read `AGENTS.md` and `MANIFESTO.md`
  before continuing. Pathfinding changes below have explicit user
  authorization only because the headed Citadel fixture proved a vertical
  navigation defect.

## What the current implementation establishes

### Authoritative city facts

1. `scripts/world/SettlementSiteAuthority.gd` establishes a deterministic
   terrain-authoritative settlement site before Citadel publication. The
   fixture records the exact site/foundation contract and waits for the
   required terrain rather than publishing a cosmetic flat plane.
2. `scripts/buildings/BuildingPartPublisher.gd` batches compatible passive
   building visuals/static collision while retaining source part identity,
   doors, actionable furniture, and metadata as individual facts.
3. `scripts/buildings/BuildingNavigationManifestBuilder.gd` derives immutable
   building navigation facts from the same published `BuildingPart` records:
   source part IDs, walkable support polygons, floor elevations, physical
   ramp/stair links, doors, bounds, and affected tiles. It does not infer
   topology from render meshes or scan colliders after the fact.
4. `scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd`,
   `NavigationBakeDescriptor.gd`, and `NavmeshWorldService.gd` now consume
   those source-derived supports/links. The work preserves the production
   NavMesh route authority and collision-backed route proof; no legacy cell
   route, direct NPC movement, teleport, named citizen exception, or
   Citadel-only path exists.

### Shared doorway/passage invariant

`scripts/buildings/FurnishingPlan.gd` now owns the final access-clearance
invariant. Every furnishing plan provides declared room accesses as protected
reservations; `FurnishingPlan.add_part()` refuses any potentially obstructive
object that overlaps one. This covers collision furniture and non-collision
wall decor (for example frames/banners), including transformed source plans
inside a castle. Floor rugs/aisle runners are intentionally allowed to mark a
route because they occupy no clearance or collision volume.

The authority is applied by:

- `CottageFurnishingPlanner.gd`
- `LandmarkFurnishingPlanner.gd`
- `CastleFurnishingPlanner.gd`, including transformed cottage/manor plans and
  its synthetic manor-room circulation bands

This is deliberately a source-layout rule, not an NPC detour or a Citadel
fixture filter.

## Evidence captured before pause

### Green focused contracts

These are recipe/contract evidence only; they are not live NPC acceptance.

```powershell
node tools/run-cottage-furnishing-layout-contract.mjs --report-path artifacts/buildings/cottage-furnishing-access-contract-vox224.json
node tools/run-landmark-furnishing-contract.mjs --report-path artifacts/buildings/landmark-furnishing-access-contract-vox224.json
$env:VOXEL_CITADEL_RESIDENCE_MANIFEST_REPORT = (Join-Path (Get-Location) 'artifacts/buildings/citadel-residence-access-contract-vox224.json')
& 'C:\Users\arkam\Desktop\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64_console.exe' --headless --path . --script res://scripts/testing/buildings/CitadelResidenceManifestContractRunner.gd
node tools/run-building-navigation-manifest-contract.mjs --report-path artifacts/buildings/building-navigation-manifest-contract-vox223.json
```

Results:

- Cottage and Town Hall furnishing contracts pass. They now assert that all
  potentially obstructive furnishings, not merely collision furniture, stay
  out of declared access corridors.
- Citadel residence contract passes across seeds `208158`, `208159`, and
  `306701`; 12 beds/citizens are deterministically assigned for each sampled
  citadel and no furnishing occupies a protected source access.
- The building-navigation-manifest contract passes across the same three
  castle seeds. It reports 182–212 source-addressable walkable supports,
  40–48 physical vertical links, and dozens of distinct elevations per seed.

### Headed Citadel Life evidence — failing, retained for diagnosis

Command:

```powershell
node tools/run-citadel-life-playtest.mjs --seed 208158 --citadel-scale 1.25 --acceptance --report-path artifacts/npc/reports/citadel-life-acceptance-layered.json --progress-path artifacts/npc/progress/citadel-life-acceptance-layered.txt --screenshot-dir artifacts/npc/screenshots/citadel-life-acceptance-layered --timeout-seconds 600
```

Artifacts:

- `artifacts/npc/reports/citadel-life-acceptance-layered.json`
- `artifacts/npc/progress/citadel-life-acceptance-layered.txt`
- `artifacts/npc/screenshots/citadel-life-acceptance-layered/`

What it proves:

- Real production `CharacterBody3D` citizens were materialized: 12 of 12;
  no spawn retries or terminal placement failures.
- The fixture has an opaque, continuously updating loading UI and reached a
  real interactive-ready state; it was not a blue-screen fallback.
- It publishes real castle collision, real doors, real furniture and the
  production NPC systems.

What it does **not** prove / why it failed:

- Daytime departures did not complete: `dayOutsideCount = 0`.
- The acceptance report is correctly `passed = false`; the subsequent night
  count reflects citizens still at home, not a successful leave-and-return
  cycle.
- The route timeline exposes a vertical topology error. An actor on a
  building floor at `y = 22.48` or `26.33` receives a NavMesh path whose next
  waypoint is terrain at `y = 21.64`, e.g.
  `(-2181.6, 22.48, 205.2) -> (-2182.95, 21.64, 205.2)`. That descends through
  structure collision, then fails the real capsule proof as
  `blocked_capsule_probe` / `no_static_route` / `unreachable_static`.
- This is the explicit basis for VOX-224's authorized narrow protected-nav
  work. It is not evidence that a citizen, door, bed, or furniture should be
  special-cased.

### Work waiting to be re-run

Immediately before pausing, `NavmeshWorldService.gd` was adjusted to select
the nearest source-declared support polygon in real 3D rather than preferring
the terrain polygon whenever the NavMesh server returned one. It also projects
onto an actual source polygon instead of an assumed axis-aligned cell.

The following rerun was intentionally interrupted by the user so the branch
could be committed. It has **not** produced acceptance evidence and must be
run first on resumption:

```powershell
node tools/run-building-navigation-manifest-contract.mjs --report-path artifacts/buildings/building-navigation-manifest-contract-vox223-v2.json
node tools/run-citadel-life-playtest.mjs --seed 208158 --citadel-scale 1.25 --acceptance --report-path artifacts/npc/reports/citadel-life-acceptance-layered-v2.json --progress-path artifacts/npc/progress/citadel-life-acceptance-layered-v2.txt --screenshot-dir artifacts/npc/screenshots/citadel-life-acceptance-layered-v2 --timeout-seconds 600
```

Inspect the second report's route timelines and `buildingNavigation` summary,
not just the result boolean. A pass requires actual daylight departure through
the home door and real strict-interior return at night.

## Linear issue progress and remaining work

| Issue | Current progress | Remaining / blocker |
| --- | --- | --- |
| VOX-217 — staged citizens/routes | Deterministic resident manifest, incremental materialization, civic order queue, queue diagnostics, loading feedback, and runtime counters are implemented in the fixture. The failed run placed 12/12 citizens without a synchronous spawn burst. | Formally blocked by VOX-219 and functionally by VOX-224/VOX-218 until real day routes work. Once vertical routes pass, profile maximum scale and prove route staging does not create a visible burst or lose an order. Do not change route internals for this item. |
| VOX-218 — headed acceptance | Runner exists and captures loading, interactive, day, and night evidence with real citizens/doors/collision. | Blocked by VOX-224. Rerun the exact command above; then run the required generic NPC baseline/regression commands and a headed normal NPC runner. Do not call contract results gameplay acceptance. |
| VOX-219 — profile | The report above separates staged load and steady frames. Observed load was **70.54 s**: ordinary boot 11.82 s, ordinary world settle 24.19 s, terrain site preparation 17.85 s, structure publication 8.23 s, navigation settle 3.00 s. Steady frame p50/p95/p99/max were **13.02/14.76/17.71/59.97 ms**; last/worst spike owner was `chunk` / terrain meshing (59.64 ms). | Repeat after a successful life cycle and at the maximum approved citadel scale. Establish whether resident/route work is a material cost before further optimization; current data says the worst observed spike is terrain/chunk work, not citizen materialization. |
| VOX-220 — batch building publication | Source-record batching is implemented and measured in the fixture: 2,176 building parts, 2,174 passive collision parts, 82 published nodes, 153 visual batches, and 7.70 s building publication in the retained profile. Doors and actionable furniture remain individual. | Fixed-seed source/collision/door equivalence and a headed physical walkthrough remain to be recorded after VOX-218 passes. Compare against a defensible unbatched baseline only if VOX-219 confirms it is worth pursuing. |
| VOX-221 — relevance activation | No acceptance-ready district relevance/approach activation is claimed. The current fixture builds a single Citadel for diagnosis; it does not prove broad-world city activation. | Only begin after VOX-219 selects a performance path. Build deterministic manifest-first district descriptors and visible-first queues; never create invisible collision ahead of visual publication or change seed order. |
| VOX-222 — terrain-authoritative site preparation | `SettlementSiteAuthority` and the fixture's site preparation wait are implemented. The retained profile records a terrain-volume site contract at fixed foundation level 21.6 and required chunk readiness before building publication. | Verify fixed-seed/save/traversal-order stability and compare site-preparation cost after the profile conclusion. Do not add a cosmetic terrain plane or duplicate collision authority. |

## Safe resumption order

1. Read `AGENTS.md`, `MANIFESTO.md`, this handoff, and inspect `git status`.
2. Compile headlessly, run the four focused contracts above, then execute the
   interrupted `layered-v2` headed acceptance command with seed `208158` and
   scale `1.25`.
3. If it still descends directly from an elevated floor to terrain, diagnose
   the source support/link topology and NavMesh adjacency. Keep any repair
   generic and source-driven: elevation transitions may use only physical
   floor/ramp supports or published links. Do not add citizen-specific routes,
   direct movement, teleporting, or a legacy route fallback.
4. When day departure and night home return pass, execute VOX-218's required
   NPC baseline/regression evidence, then finish VOX-219's maximum-scale
   profile before selecting VOX-217/220/221/222 optimizations.
5. Maintain the shared furnishing guard. Any new building/furniture planner
   must initialize its `FurnishingPlan` with semantic access reservations;
   transformed plans must carry them into their parent plan.

## Relevant code and command map

- Fixture: `scenes/testing/npc/CitadelLifePlaytest.tscn`,
  `scripts/testing/npc/CitadelLifePlaytestRunner.gd`,
  `tools/run-citadel-life-playtest.mjs`
- Site/terrain: `scripts/world/SettlementSiteAuthority.gd`,
  `scripts/TerrainVolumeService.gd`, `scripts/terrain/VoxelTerrainRuntime.gd`
- Source building/navigation facts:
  `scripts/buildings/BuildingPartPublisher.gd`,
  `scripts/buildings/BuildingNavigationManifestBuilder.gd`,
  `scripts/testing/buildings/BuildingNavigationManifestContractRunner.gd`,
  `tools/run-building-navigation-manifest-contract.mjs`
- Protected navigation integration:
  `scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd`,
  `scripts/npc_ai/contracts/NavigationBakeDescriptor.gd`,
  `scripts/npc_ai/navigation/NavmeshWorldService.gd`,
  `scripts/npc_ai/routing/NavmeshRoutePlanner.gd`
- Doorway/furnishing invariant:
  `scripts/buildings/FurnishingPlan.gd`,
  `scripts/buildings/InteriorFurnishingLayout.gd`,
  `scripts/buildings/CottageFurnishingPlanner.gd`,
  `scripts/buildings/LandmarkFurnishingPlanner.gd`, and
  `scripts/buildings/CastleFurnishingPlanner.gd`

## Current stop condition

No runtime process remains active. This branch is intentionally paused after
the commit containing this document. Do not represent VOX-218 as complete
until its headed leave/day/return/night acceptance is green.
