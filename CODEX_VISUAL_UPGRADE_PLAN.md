# Codex Visual Upgrade Plan — Voxel Biome World Godot

This plan is written for the uploaded project, not for a generic Godot sample. Execute it one phase at a time. Do not ask Codex to perform the entire roadmap in one run.

## How to use this plan

1. Put this file at the repository root as `CODEX_VISUAL_UPGRADE_PLAN.md`.
2. Start each Codex session with: **“Read `CODEX_VISUAL_UPGRADE_PLAN.md`. Execute only Phase N. Stop after its report and commit.”**
3. Review the screenshots at every visual gate before authorizing the next phase.
4. Never use “make it prettier” as the sole instruction. Point to one or two concrete defects in the latest captures.

Every phase must end with:

- The existing automated playtest suite passing.
- The deterministic world signature still matching, unless the phase explicitly changes generation and that change was approved.
- New visual captures generated from the same fixed cases.
- A short before/after report with performance measurements.
- One focused Git commit.
- Codex stopping instead of wandering into the next phase like an unsupervised wizard.

---

# 1. Current project audit

The uploaded project currently has:

- Godot 4.6 configured with Forward+.
- A code-only `Main.tscn`; almost the entire world is built at runtime.
- 58 GDScript files and roughly 22,800 lines of GDScript.
- No visual art assets under `assets/`; the current assets are audio only.
- A substantial automated playtest runner with 137 passing results in the supplied report.
- A 49-chunk active world around the player at the default render distance.
- Existing visual/performance instrumentation in `MainDiscoveryFlow.gd`.
- Existing fixed playtest destinations for town, forest, mountain, water, mine, camp, combat, and collapse cases.

The main visual hotspots are:

- `scripts/MainSetupScene.gd`
  - `setup_materials()`
  - `setup_environment()`
  - `make_sky_body()`
- `scripts/MainGameLoop.gd`
  - `update_sky()`
  - `apply_weather_lighting()`
- `scripts/MainPlaytestTools.gd`
  - `build_chunk_mesh()`
  - `spawn_chunk_detail_batches()`
  - `detail_mesh()`
  - `make_tree()`
  - `make_rock()`
- `scripts/WeatherSystem.gd`
  - sphere clouds, individual sphere stars, and precipitation visuals
- `scripts/MainChunkTerrain.gd`
  - block and utility visuals composed from fresh `BoxMesh` instances
- `scripts/StructureSystem.gd`
  - generated walls and flat rectangular roof slabs
- `scripts/NpcVisualFactory.gd`
- `scripts/HostileVisualFactory.gd`
- `scripts/GameHudLayoutBuilder.gd`
- `scripts/GameHudPanelBuilder.gd`
- `scripts/GameHudRenderer.gd`

The main gameplay script is also the end of a deep inheritance chain:

```text
Main.gd
→ MainPropFactory.gd
→ MainChunkTerrain.gd
→ MainInteractionFlow.gd
→ MainPlaytestTools.gd
→ MainRuntimeTools.gd
→ MainDiscoveryFlow.gd
→ MainHudFlow.gd
→ MainWorldEntities.gd
→ MainCharacterState.gd
→ MainGameLoop.gd
→ MainSetupScene.gd
→ MainSaveState.gd
→ MainCore.gd
→ MainInterface.gd
```

Do not refactor that chain during the visual overhaul. Add isolated visual systems and make small integration hooks. A renderer upgrade is already enough adventure for one expedition.

The Git worktree in the uploaded zip is heavily uncommitted relative to its included `.git` history. Phase 0 is mandatory.

---

# 2. Target art direction

Use this as the written art brief:

- Late-GameCube / early-PS2-inspired low-poly presentation.
- Strong, recognizable silhouettes from medium distance.
- Chunky geometry with deliberate faceting and small bevels.
- Restrained, palette-controlled colors rather than fluorescent highlights.
- Warm daylight, cool shadow fill, readable moonlit nights.
- Low-resolution, hand-painted-looking surface breakup where useful.
- No photorealism, no high-frequency photographic materials, and no glossy plastic terrain.
- Environmental assets should look authored while remaining deterministic and procedurally placed.
- The world generator remains in Godot.
- Blender is an offline asset factory for reusable pieces, not the world generator.

Initial content budgets:

| Asset family | Starting budget |
|---|---:|
| Small rock | 60–220 triangles |
| Bush or grass cluster | 20–160 triangles |
| Tree | 300–1,200 triangles, one combined mesh with a few material surfaces |
| Small prop | 50–500 triangles |
| Roof/window/door module | 20–400 triangles |
| Environment textures | Usually 64×64 or 128×128; no initial texture over 512×512 |

These are guardrails, not a competition to use every triangle.

---

# 3. Non-negotiable engineering rules

Codex must obey these throughout the roadmap:

1. **Preserve gameplay.** Do not change input, survival, combat, inventory, objectives, save format, collision behavior, or interaction ranges as part of an art task.
2. **Preserve deterministic generation.** The same seed must retain the same terrain, prop IDs, prop types, block cells, structures, and gameplay-relevant placements.
3. **Do not consume shared generation RNG differently.** Visual variation must use a separate RNG derived from stable IDs, or the existing RNG draw sequence must be intentionally preserved.
4. **Keep collision separate from art.** Existing primitive collision shapes may remain even when visuals become authored meshes.
5. **Provide fallbacks.** If a generated `.glb`, material, or shader is missing, use the existing primitive visual rather than breaking the game.
6. **Reuse resources.** Cache meshes, materials, textures, shaders, and `PackedScene` resources. Never load a GLB or create a material once per tree.
7. **Use finite variant libraries.** Generate several reusable variants and instance them. Do not export a unique model for every world object.
8. **Keep Blender deterministic and headless.** Asset scripts must run from the command line and reproduce the same output from the same source revision.
9. **Do not download third-party assets without explicit approval.** The intended pipeline is self-generated and repository-owned.
10. **Do not combine art-direction changes with unrelated architecture cleanups.** One problem per commit.
11. **Never delete or weaken existing tests just to make a phase pass.** Update a test only when an explicitly approved visual implementation invalidates an implementation-specific assertion while preserving its behavioral purpose.
12. **Record relative performance.** Compare each phase to the immediately preceding capture on the same machine and settings.

---

# 4. Intended visual architecture

Create these folders gradually as their phases begin:

```text
assets/
  visual/
    generated/
      environment/
      structures/
      characters/
      textures/
    materials/
    ui/
resources/
  visual/
  ui/
scenes/
  visual/
scripts/
  visual/
shaders/
tools/
  blender/
  art/
artifacts/
  visual/          # ignored; local captures and reports
  baselines/       # selected committed reference captures only
```

Primary new components:

- `VisualStyle.gd`: one data resource for lighting, palette, fog, material, and quality values.
- `VisualAssetRegistry.gd`: cached lookup of generated scenes/meshes with primitive fallbacks.
- `BiomeVisualProfile.gd`: added later when biome assets exist.
- `VisualCaptureRunner.gd`: deterministic screenshot runner separate from the 5,000-line functional playtest runner.
- Blender Python generators: only for APIs that require Blender Python.
- PowerShell wrappers: consistent with the existing Windows playtest tooling.
- Optional Node.js validation/manifest utilities where ordinary scripting is sufficient.

---

# 5. Reusable Codex operating prompt

Paste this before the phase-specific prompt:

```text
Work only on the requested phase of CODEX_VISUAL_UPGRADE_PLAN.md.

Before editing:
1. Read the relevant existing scripts completely.
2. Run git status and do not discard any user work.
3. Run the existing playtest and record whether it passes.
4. Inspect the previous phase's visual captures and report.

During editing:
- Preserve gameplay, save compatibility, collision, and deterministic world generation.
- Keep changes narrowly scoped.
- Reuse resources and avoid per-instance loading/material creation.
- Add fallback behavior for generated visual assets.
- Do not refactor the Main inheritance chain.

After editing:
1. Run all existing automated playtests.
2. Run the deterministic world-signature check.
3. Generate all standard visual captures.
4. Report changed files, visual differences, test results, and relative performance.
5. Commit with the phase's requested commit message.
6. Stop. Do not begin another phase.
```

---

# Phase 0 — Protect the current game and establish a clean baseline

## Goal

Checkpoint all current work before touching graphics. The uploaded zip’s Git history does not contain most of the present game, so visual work must not start on top of an unprotected working tree.

## Codex prompt

```text
Execute Phase 0 only.

Do not change game code.

1. Inspect git status and preserve every existing file.
2. Create a new branch named visual-overhaul from the current state.
3. Run tools/run-playtest.ps1 with the configured Godot executable.
4. Confirm that the current report passes and record the result count and elapsed time.
5. Create docs/VISUAL_BASELINE.md containing:
   - Godot version and renderer
   - current test result count
   - current key performance/debug values
   - current visual implementation summary
   - the exact commands used
6. Commit all current project work as a checkpoint. Do not include .godot caches or ignored playtest output.
7. Use commit message:
   Checkpoint game before visual overhaul
8. Stop.

Do not reset, clean, rebase, or discard the existing dirty worktree.
```

## Acceptance criteria

- All existing tests pass.
- The current source is fully represented in Git.
- `git status --short` is clean after the checkpoint, except intentionally ignored generated reports.
- No game behavior or visual value changed.

---

# Phase 1 — Add deterministic visual captures and world-signature protection

## Goal

Create the feedback loop Codex needs before changing art. This phase should produce repeatable screenshots and prove that later visual work does not silently alter procedural generation.

## Add

```text
scenes/VisualCapture.tscn
scripts/visual/VisualCaptureRunner.gd
tools/run-visual-captures.ps1
tools/run-world-signature.ps1
artifacts/visual/                  # gitignored
artifacts/world-signature/         # gitignored
artifacts/baselines/                # selected captures may be committed
```

A separate runner is preferable to adding more responsibilities to `PlaytestRunner.gd`.

## Required capture cases

Use the existing `run_playtest_case()` destinations and the stable `atlas-1492` seed:

| Case | Playtest destination | Time | Weather | HUD |
|---|---|---:|---|---|
| `town_noon` | town | noon | clear | hidden |
| `town_sunset` | town | sunset | clear | hidden |
| `forest_midnight` | forest | midnight | clear | hidden |
| `forest_rain` | forest | late afternoon | rain | hidden |
| `mountain_day` | mountain | morning | clear | hidden |
| `water_overcast` | water | afternoon | cloudy/rain-light | hidden |
| `hud_gameplay` | town | noon | clear | visible |

Each capture must freeze time, player motion, procedural weather evolution, camera bob, and hand sway. Use a fixed camera transform relative to the selected playtest target. Write a JSON metadata file beside the captures containing seed, case, time, weather, camera transform, resolution, renderer, and basic performance values.

## World signature

For `atlas-1492`, generate a stable signature from fixed regions that includes at minimum:

- Selected terrain heights and biome IDs.
- Loaded chunk keys.
- Prop IDs, prop kinds/materials, and rounded positions for a fixed set of chunks.
- Generated structure counts.
- Generated block type/cell pairs in the forced town.
- Town home records.

The default command compares against the committed baseline and fails on differences. A separate explicit `-UpdateBaseline` option may rewrite it. Never update the signature baseline automatically after a mismatch.

## Codex prompt

```text
Execute Phase 1 only.

Add a deterministic visual capture runner and deterministic world-signature runner. Do not improve graphics yet.

Requirements:
- Keep the existing functional PlaytestRunner unchanged except for a tiny shared helper only if absolutely necessary.
- Use the stable atlas-1492 seed and existing playtest-case destinations.
- Freeze time, weather progression, movement, head bob, and hand sway during capture.
- Capture town_noon, town_sunset, forest_midnight, forest_rain, mountain_day, water_overcast, and hud_gameplay.
- Save PNGs and a JSON metadata report.
- Add a world-signature baseline and comparison command.
- Add all local capture output folders to .gitignore, while allowing selected baseline files under artifacts/baselines/ to be committed.
- Run the normal playtest, signature check, and capture suite.
- Commit selected baseline captures and the signature baseline.
- Use commit message:
  Add deterministic visual regression harness
- Stop.
```

## Acceptance criteria

- Repeating the capture command produces the same composition and stable metadata.
- Repeating the world-signature command passes.
- Existing 137 test results still pass; any newly added tests also pass.
- No intended visual change from the Phase 0 baseline.

---

# Phase 2 — Introduce a data-driven visual style and repair lighting

## Goal

Fix the most damaging problems visible in the screenshots: clipped daylight, flat cyan background, weak depth separation, and nearly black night scenes.

## Add

```text
scripts/visual/VisualStyle.gd
resources/visual/gamecube_style.tres
shaders/stylized_sky.gdshader       # only if a procedural SkyMaterial is insufficient
```

## Modify narrowly

- `scripts/MainInterface.gd`: preload/stub only if needed.
- `scripts/MainCore.gd`: store the style resource and visual debug/capture flags.
- `scripts/MainSetupScene.gd`: `setup_materials()` and `setup_environment()`.
- `scripts/MainGameLoop.gd`: `update_sky()` and `apply_weather_lighting()`.
- `scripts/PlaytestRunner.gd`: add value/range assertions, not screenshot comparisons.

## Required changes

- Replace `Environment.BG_COLOR` with a real sky setup.
- Select an explicit filmic tonemapper and calibrated exposure.
- Use sky-derived or coordinated ambient lighting instead of a disconnected constant color.
- Reduce noon sunlight from the current clipping range.
- Raise night midtones enough to preserve terrain and prop silhouettes.
- Add restrained depth fog coordinated with sky/weather colors.
- Add moderate SSAO if supported by the active renderer.
- Configure directional shadow distance and softness deliberately.
- Preserve visible sun and moon discs for now.
- Put all major values in `gamecube_style.tres`, not scattered magic numbers.
- Do not change terrain geometry, terrain materials, props, water, cloud meshes, stars, UI, or structures in this phase.

## Visual acceptance criteria

- Sand and snow retain detail at noon rather than becoming flat pale yellow/white.
- Forest terrain and trunks remain readable at midnight.
- Distant hills separate from foreground through atmosphere rather than extreme darkness.
- Rain darkens and cools the scene without crushing it.
- The sky has a horizon/zenith relationship and coordinated sunrise/sunset colors.
- No excessive bloom, vignette, chromatic aberration, or cinematic soup.

## Codex prompt

```text
Execute Phase 2 only: data-driven environment lighting.

Create VisualStyle.gd and resources/visual/gamecube_style.tres. Migrate environment values into that resource and repair setup_environment(), update_sky(), and apply_weather_lighting().

Target:
- warm daylight
- cool shadow fill
- readable nights
- controlled highlights
- soft atmospheric depth
- late-GameCube-style color response

Do not alter terrain geometry/materials, props, buildings, weather geometry, water, UI, or gameplay.

Add automated assertions that the expected tonemapper, fog, ambient source, and sensible day/night energy ranges are active.

Run tests, signature comparison, and all standard captures. Include a side-by-side contact sheet or clearly named before/after files in the report.

Commit message:
Improve environment lighting and night readability

Stop after the commit.
```

---

# Phase 3 — Improve terrain shading without changing terrain gameplay

## Goal

Remove the untextured vertex-color look and mountain striping while preserving terrain heights and collision behavior.

## Add

```text
shaders/stylized_terrain.gdshader
resources/visual/terrain_material.tres
scripts/visual/TerrainMaterialFactory.gd   # only if runtime resource creation remains necessary
```

## First: geometry-safe normal repair

`build_chunk_mesh()` currently emits triangles with vertex colors and calls `generate_normals()`. For the first implementation:

- Keep every vertex position unchanged.
- Keep the existing triangle indices/order unchanged.
- Compute smooth normals from neighboring height samples, including a one-cell border outside the chunk, so adjacent chunk lighting agrees.
- Give skirts intentional outward normals or place them on a separate surface.
- Do not change the collision mesh topology in this phase.

Only if striping remains after explicit normals and the shader pass may Codex experiment with alternate visual triangulation. If that becomes necessary, create a separate visual mesh while retaining the legacy collision mesh and prove movement tests still pass.

## Terrain shader requirements

- Continue using existing vertex colors as biome tint/blend input.
- Add world-space macro breakup so hills are not one flat color.
- Add slope-based rock tint/material response.
- Add altitude-aware snow/pale-rock response.
- Add subtle top-versus-side value variation.
- Keep roughness high and specular restrained.
- Avoid dense photoreal noise.
- Prefer a shader/procedural-noise first pass. Add tiny generated texture tiles only if they visibly improve the captures.
- Preserve the biome identity encoded by `BIOME_COLORS`; centralize those colors in the visual style only after parity is verified.

## Codex prompt

```text
Execute Phase 3 only: terrain normals and stylized terrain material.

Modify build_chunk_mesh() without changing terrain heights, gameplay cells, or collision behavior. Keep triangle topology unchanged initially and compute explicit seam-safe smooth normals from neighboring height samples.

Add a stylized world-space terrain shader that uses the current vertex colors, slope, altitude, and low-frequency variation. The result must remain low-poly and palette-controlled, not photorealistic.

Do not touch water, props, structures, weather geometry, characters, or UI.

Add tests for:
- unchanged terrain signature
- matching normals across selected chunk edges
- terrain shader/material assigned
- collision shapes still present for all loaded chunks

Run all tests and captures.

Commit message:
Add stylized terrain shading and seam-safe normals

Stop after the commit.
```

## Acceptance criteria

- No visible lighting seams at chunk borders.
- Mountain faces have readable form without repeated bright/dark zebra bands.
- Terrain remains recognizable by biome.
- Existing movement, grounding, slope, jump, and terrain collision tests pass unchanged.

---

# Phase 4 — Stylize water, sky objects, and weather visuals

## Goal

Replace the flat transparent water and floating sphere weather visuals while retaining the existing weather simulation and gameplay effects.

## Add

```text
shaders/stylized_water.gdshader
resources/visual/water_material.tres
shaders/stylized_clouds.gdshader       # or generated cloud-card material
scripts/visual/SkyVisualController.gd  # if useful to separate presentation from WeatherSystem state
```

## Water requirements

- Keep the current large water plane and water level.
- Add shallow/deep color variation, Fresnel response, two slow wave/noise layers, restrained vertex motion, and shoreline emphasis where practical.
- Keep transparency controlled; do not make the entire ocean look like blue glass.
- Coordinate water tint with time of day and weather through shader parameters rather than replacing the material’s albedo every frame.

## Weather requirements

- Preserve `WeatherSystem` state, biome profiles, precipitation behavior, and snapshot fields.
- Replace 160 individual star `MeshInstance3D` nodes with a sky shader or one `MultiMeshInstance3D` while preserving logical star count in diagnostics.
- Replace flattened sphere clouds with a small reusable low-poly cloud mesh library, a cloud-card system, or a sky shader.
- Keep rain and snow MultiMesh-based.
- Do not change survival wet/cold calculations.
- Keep tests that require rain, snow, and star visibility meaningful.

## Codex prompt

```text
Execute Phase 4 only: water and weather presentation.

Create a stylized water shader and replace the current flat transparent StandardMaterial3D behavior. Keep the same water plane, level, collision assumptions, and weather gameplay.

Refactor WeatherSystem presentation so stars are not 160 separate mesh nodes and clouds are no longer flattened spheres. Preserve weather state, constants, snapshot semantics, and precipitation gameplay.

Do not add Blender assets yet. Use Godot meshes/shaders for this phase.

Run tests, signature comparison, captures, and relative performance measurements.

Commit message:
Stylize water and weather presentation

Stop after the commit.
```

## Acceptance criteria

- Water reads as a stylized surface in clear, sunset, and overcast captures.
- Clouds have grouped, intentional silhouettes.
- Stars no longer incur one node per star.
- Rain and snow remain visible and functional.
- No change to weather-driven survival behavior.

---

# Phase 5 — Build the Blender asset factory, without integrating it yet

## Goal

Prove that Codex can reliably generate reusable low-poly assets through Blender before game code depends on them.

## Add

```text
tools/blender/find-blender.ps1
tools/blender/generate_environment_assets.py
tools/blender/validate_generated_assets.py
tools/blender/build-environment-assets.ps1
tools/art/validate-visual-manifest.mjs
assets/visual/generated/environment/
assets/visual/generated/visual-manifest.json
```

Blender Python is appropriate here because Blender’s API requires it. Use Node.js for manifest validation or ordinary file processing where Blender APIs are not needed.

## First generated pack

Generate deterministic variants:

- 6 broadleaf trees.
- 4 conifer/taiga trees.
- 3 sparse savanna/acacia-like trees.
- 6 rocks with clearly different silhouettes.
- 4 bushes.
- 3 stumps/logs.

## Asset rules

- Ground-centered pivot.
- Upright and correctly scaled after Godot import.
- Applied transforms.
- Triangulated export.
- Deliberately flat or selectively smooth shading.
- Tiny bevels only where they improve silhouette/highlights.
- A small, consistent material-slot vocabulary such as `trunk`, `leaf_primary`, `leaf_secondary`, `rock_primary`, and `rock_accent`.
- One combined mesh per asset where practical; do not export five separate canopy objects as five drawables.
- No armatures or animation in this phase.
- Export `.glb` files.
- Script output must be deterministic and idempotent.
- The manifest must include ID, path, family, biome tags, triangle count, bounding box, pivot check, and material slots.
- The validator must reject missing files, zero-size meshes, excessive triangle counts, wrong pivots, or unexpected materials.
- The Python source and generated GLBs are committed. Do not require a `.blend` file as the source of truth.

## Codex prompt

```text
Execute Phase 5 only: create an offline Blender asset factory.

Detect the installed Blender executable on Windows, with an override parameter. Write deterministic headless Blender scripts that generate and export the first environment pack:
- 6 broadleaf trees
- 4 conifers
- 3 sparse savanna trees
- 6 rocks
- 4 bushes
- 3 stumps/logs

Export each asset as GLB under assets/visual/generated/environment and write a visual-manifest.json containing geometry and validation metadata.

Add a validation command and run it. Open/import representative assets in Godot sufficiently to verify orientation, scale, material slots, and pivots, but do not replace any in-game visuals yet.

Do not edit world generation or make_tree/make_rock in this phase.

Commit message:
Add deterministic Blender environment asset factory

Stop after the commit.
```

## Visual gate

Review a contact sheet or Godot asset-gallery screenshot showing all variants. Do not proceed until:

- Broadleaf, conifer, and savanna silhouettes are distinguishable.
- Rocks are visibly faceted and not egg-shaped.
- Assets look like one family.
- Scale and pivots are correct.

Iterate this generator before integrating mediocre assets. Producing fifty mediocre trees faster is not a victory.

---

# Phase 6 — Integrate generated trees and rocks safely

## Goal

Replace the most visible primitive props while preserving interaction, drops, collisions, falling-tree behavior, and deterministic placement.

## Add

```text
scripts/visual/VisualAssetRegistry.gd
scripts/visual/BiomeVisualProfile.gd
resources/visual/biomes/*.tres
```

## Modify

- `scripts/MainInterface.gd`: preload/stub only if needed.
- `scripts/MainCore.gd`: registry/profile references.
- `scripts/MainSetupScene.gd`: initialize the registry once.
- `scripts/MainPlaytestTools.gd`: `make_tree()` and `make_rock()` only.
- `scripts/MainSetupScene.gd`: verify `spawn_falling_tree_visual()` duplicates the new visual hierarchy safely.
- `scripts/PlaytestRunner.gd`: strengthen prop visual and fallback tests.

## Determinism warning

The existing `make_tree()` and `make_rock()` consume the same `RandomNumberGenerator` used by the surrounding chunk prop loop. Simply replacing their random calls would shift later prop decisions.

Codex must do one of these safely:

1. Extract the current random draws into a visual-spec function that consumes them in exactly the same order, then render either the old fallback or new asset from that spec; or
2. Prove through the committed world signature that a separate deterministic visual RNG can be introduced without changing any gameplay-relevant generated output.

Option 1 is safer for this project.

## Integration rules

- Keep the existing `StaticBody3D`, metadata, drops, and collision shapes.
- Instance the generated asset as a visual child.
- Choose variants deterministically by biome and stable prop ID.
- Cache all `PackedScene` resources.
- Override material slots through the shared style/profile system if needed.
- Keep current primitive construction as fallback.
- Ensure falling-tree duplication works.
- Do not replace forage, wildlife, ore, details, buildings, or characters yet.

## Codex prompt

```text
Execute Phase 6 only: integrate generated tree and rock visuals.

Add VisualAssetRegistry and biome visual profiles. Replace only the visual children created by make_tree() and make_rock(). Preserve the existing StaticBody3D roots, metadata, drop behavior, primitive collision shapes, and falling-tree behavior.

Critically, preserve the existing shared RNG consumption sequence or prove exact parity with the committed world signature. Use stable prop IDs for visual variant selection without allowing visual implementation details to alter later world generation.

Add primitive fallbacks for missing/failed assets and tests that exercise the fallback path.

Run all tests, signature comparison, captures, and performance measurements.

Commit message:
Replace primitive trees and rocks with generated assets

Stop after the commit.
```

## Acceptance criteria

- Forest and mountain captures show clearly varied silhouettes.
- `tree_fall_visual_and_logs` still passes.
- Rock/tree drops and targeting still work.
- World signature is unchanged.
- Missing one GLB deliberately triggers a working primitive fallback in a test.
- No per-tree `load()` calls and no per-tree material creation.

---

# Phase 7 — Upgrade grass, flowers, bushes, and small details

## Goal

Replace the current tiny boxes, cylinders, and spheres while retaining the existing efficient per-chunk MultiMesh batching.

## Approach

Do not turn every blade of grass into a node. Keep `spawn_chunk_detail_batches()` and `MultiMeshInstance3D` as the foundation.

Generate or construct a small reusable detail mesh library:

- Two grass clusters.
- Flower stem/bloom combined variants.
- Reeds.
- Pebbles.
- Snow clumps.
- Scrub.
- Leaf litter.
- Optional bush variants from the Blender pack.

Use either low-poly solid geometry or alpha-scissored cards. Avoid alpha blending for foliage unless necessary. Add subtle wind only to foliage vertices, with deterministic phase variation through MultiMesh custom data or instance colors.

Add distance visibility/fade ranges so tiny details do not render to the horizon.

## Codex prompt

```text
Execute Phase 7 only: improve chunk detail vegetation and ground clutter.

Keep the existing per-chunk MultiMesh batching. Replace detail_mesh() primitives with a cached low-poly detail library and shared foliage materials. Add restrained deterministic color/scale variation and optional subtle wind without creating per-instance nodes or materials.

Add sensible visibility ranges for small details. Preserve biome placement rules and the existing detail instance counts/signature.

Do not alter major trees, rocks, terrain generation, structures, characters, or HUD.

Commit message:
Upgrade procedural foliage and ground details

Stop after tests, captures, report, and commit.
```

## Acceptance criteria

- Ground details read as clusters rather than pins and marbles.
- Existing chunk detail batch test remains meaningful.
- No large draw-call increase.
- Details fade before becoming shimmering distant noise.

---

# Phase 8 — Improve blocks, town materials, and roofs

## Goal

Make generated towns look intentional without replacing the procedural structure system or breaking individually interactable blocks.

## Part A: shared block mesh and material polish

`add_block_mesh()` currently creates a fresh `BoxMesh` resource for every visual piece. Replace this with cached reusable unit meshes scaled at the instance level.

Create:

- A subtly chamfered unit block mesh.
- A plain unit block fallback.
- Shared stylized materials for wood, stone, plaster/dirt, glass, metal, roof, and paths.
- World-space or compact-atlas surface breakup.

Preserve collision sizes and block roots.

## Part B: pitched roof presentation

Do not replace the whole town with Blender-authored houses. `StructureSystem` must continue deciding footprints, doors, windows, utilities, and block cells.

A safe implementation is to keep the current roof block cells/colliders and attach roof-role visual meshes:

- left/right slope
- ridge
- eave/end cap

A generated wedge/ridge library may come from Blender or a Godot mesh builder. The roof should remain made from individually destroyable block entities. Avoid a single decorative roof that remains floating after its supporting blocks are destroyed.

Use stable structure/cell metadata rather than consuming additional structure RNG.

## Part C: modular accents

Generate and add a small set of reusable accents:

- Window frame.
- Door frame.
- Corner timber.
- Chimney.
- Sign.
- Fence post/rail.
- Crate/barrel.

These may be Blender-generated, but Godot still determines their placement.

## Codex prompt

```text
Execute Phase 8 only: town and structure presentation.

First replace per-call BoxMesh creation in add_block_mesh() with cached shared unit meshes scaled by instances. Add a subtle chamfered block visual and shared stylized building materials while preserving all collision profiles and interactions.

Then improve generated roofs using individually attached slope/ridge/eave visuals on the existing roof block entities. Keep structures procedural, block-addressable, destroyable, and compatible with structural integrity checks.

Add a small generated modular accent pack for frames, beams, chimney, sign, fence, crate, and barrel, placed by Godot using stable hashes rather than consuming structure RNG.

Do not replace entire buildings with monolithic GLBs.

Run all structure, door, shelter, collapse, save, and movement tests, plus signature and visual captures.

Commit message:
Polish procedural buildings and generated roofs

Stop after the commit.
```

## Acceptance criteria

- Town silhouettes read as buildings from a distance.
- The giant flat overhanging slab look is gone or greatly reduced.
- Doors, windows, paths, shelter, and structural-collapse behavior still pass.
- Breaking a roof block removes its associated roof visual.
- No monolithic house asset controls gameplay geometry.

---

# Phase 9 — Give the HUD a coherent visual identity

## Goal

Replace the default-control appearance without changing HUD behavior.

## Add

```text
resources/ui/game_theme.tres
assets/visual/ui/                 # generated nine-patches, frames, separators if needed
scripts/visual/HudStyleFactory.gd # only if a .tres theme cannot express everything
```

## Modify

- `scripts/GameHud.gd`
- `scripts/GameHudLayoutBuilder.gd`
- `scripts/GameHudPanelBuilder.gd`
- `scripts/GameHudRenderer.gd`
- `scripts/InventorySlotButton.gd`

## Requirements

- Apply one root `Theme` resource.
- Give panels, buttons, bars, tooltips, dialogue, and hotbar consistent spacing/borders.
- Use an unmistakable selected-slot frame, not only yellow text.
- Keep font sizes readable at 1280×720.
- Hide seed, chunk count, coordinates, build label, and other debug data behind the existing performance/debug controls for normal play.
- Pre-create hotbar slot controls and update them instead of clearing/rebuilding the hotbar on every render.
- Preserve all inventory drag/drop, button signals, keyboard shortcuts, dialogue, settings, and menus.
- Keep procedural item icons for now; style their frames rather than replacing the icon system.

## Codex prompt

```text
Execute Phase 9 only: HUD theme and hotbar presentation.

Create and apply a coherent low-resolution-inspired Godot Theme across the HUD. Improve panels, buttons, vital displays, progress bars, dialogue, menus, inventory slots, and the selected hotbar slot.

Refactor render_hotbar() to reuse pre-created slot controls rather than clearing and recreating them, without changing input, signals, drag/drop, or inventory behavior.

Move normal debug readouts behind debug/performance visibility.

Do not alter 3D visuals in this phase.

Commit message:
Add cohesive HUD theme and reusable hotbar slots

Stop after all HUD tests, captures, report, and commit.
```

## Acceptance criteria

- `hud_gameplay` visibly belongs to the same game as the 3D world.
- Selected item is obvious at a glance.
- UI remains readable against day and night scenes.
- Existing HUD and inventory tests pass.

---

# Phase 10 — Replace NPC and hostile body primitives without full rigging

## Goal

Improve character silhouettes efficiently without beginning with a complex skeletal-animation pipeline.

The current NPC and hostile systems already assemble visual parts and animate held-item anchors. Preserve that structure initially.

## Blender pack

Generate modular low-poly parts:

- NPC torso/tunic variants.
- Head variants.
- Hood/hair/hat variants.
- Arm parts.
- Hostile torso/head/eye/core/shard variants.

Keep each part’s pivot appropriate for current procedural assembly. Use shared material slots so existing body/accent/skin/hostile palette variation remains functional.

## Modify

- `scripts/NpcVisualFactory.gd`
- `scripts/HostileVisualFactory.gd`
- `scripts/NpcSystem.gd` only if required for visual-state hooks

## Requirements

- Keep existing capsule collision.
- Keep current combat stats and AI.
- Keep held-item anchors and attack animation behavior.
- Keep current role/color variation.
- Show `Label3D` names only when nearby, targeted, or in dialogue instead of always drawing through geometry.
- Use primitive fallback parts when generated assets are absent.
- Do not introduce a skeleton/armature unless modular-part results are clearly insufficient and a separate phase is approved.

## Codex prompt

```text
Execute Phase 10 only: modular NPC and hostile visual assets.

Use Blender to generate reusable low-poly body-part meshes that fit the current NpcVisualFactory and HostileVisualFactory assembly approach. Replace primitive torso/head/arm components while preserving collision, AI, stats, held-item anchors, combat animations, and material variation.

Change name labels so they appear only when contextually useful rather than always rendering through world geometry.

Keep primitive fallbacks. Do not introduce full skeletal rigging in this phase.

Commit message:
Upgrade modular NPC and hostile visuals

Stop after tests, captures, report, and commit.
```

---

# Phase 11 — Final consistency, performance, and release pass

## Goal

Make all visual systems behave like one art direction and ensure the overhaul has not traded a prototype look for a frame-time crime scene.

## Tasks

- Review every standard capture side by side.
- Coordinate palette values across terrain, props, buildings, characters, water, weather, particles, and UI.
- Audit imported GLBs for duplicate embedded materials and replace them with shared resources where practical.
- Audit visibility ranges and shadow casting:
  - tiny details: no shadows
  - distant foliage: reduced or disabled shadows
  - important nearby trees/buildings: shadows retained
- Add simple LOD only where captures/performance prove it is necessary.
- Record actual rendering statistics if supported, along with existing `debug_performance_state()` values.
- Ensure no asset loads or material allocations occur in per-frame update paths.
- Ensure all asset build scripts run from a clean checkout.
- Ensure primitive fallbacks still function.
- Ensure release gameplay hides debug information by default.
- Run the complete automated suite and every capture case twice.
- Produce `docs/VISUAL_OVERHAUL_REPORT.md` containing:
  - before/after capture index
  - architecture summary
  - generated asset inventory
  - test results
  - deterministic signature result
  - relative performance table
  - known visual limitations
  - exact asset rebuild commands

## Performance gate

At the same seed, capture, resolution, render distance, and quality settings:

- No unexplained persistent frame-time regression greater than 20% from the Phase 1 baseline.
- No runaway increase in visible mesh nodes or materials.
- No per-frame creation of meshes/materials/textures.
- No regression in chunk streaming or test duration large enough to suggest repeated asset loading.

A measured regression may be accepted only when the visual benefit is clear and the report documents it.

## Codex prompt

```text
Execute Phase 11 only: final consistency and performance pass.

Do not add a new visual feature category. Audit and tune the existing overhaul for palette consistency, resource reuse, import settings, shadow policy, visibility ranges, loading behavior, and frame time.

Run the full functional suite, deterministic signature, asset validators, and all visual captures twice from a clean working tree. Produce docs/VISUAL_OVERHAUL_REPORT.md with before/after references, test results, generated asset inventory, performance comparison, rebuild commands, and known limitations.

Commit message:
Finalize visual overhaul and performance validation

Stop after the commit and final report.
```

---

# 6. Review checklist after every visual phase

Use this compact review before authorizing the next phase:

## Functional

- Does the normal automated playtest pass?
- Does the world signature match?
- Are save/load and generated structure tests still passing?
- Do missing visual assets fall back safely?

## Visual

- Is the silhouette better, or merely more detailed?
- Does the new work match the palette and lighting?
- Does it remain readable at night and in rain?
- Is distant scenery calmer than foreground scenery?
- Did any object become glossy, noisy, or photorealistic by accident?

## Performance

- Did frame time change?
- Did mesh-node or draw estimates change substantially?
- Are shared assets actually shared?
- Is anything loading or allocating every frame?

## Scope

- Did Codex change unrelated gameplay?
- Did it refactor the inheritance chain?
- Did it start the next phase without approval?

---

# 7. Recommended stopping points

The game should already look substantially better after Phase 4, before Blender integration.

The strongest cost/benefit milestone is the end of Phase 8:

- repaired lighting
- better terrain
- stylized water/weather
- authored-looking generated trees and rocks
- improved foliage
- recognizable towns and roofs

At that point, reassess whether characters need Phase 10 immediately. Environment and UI usually dominate the screenshots; characters can wait if gameplay development has higher priority.

---

# 8. First command to give Codex

```text
Read CODEX_VISUAL_UPGRADE_PLAN.md and execute Phase 0 only. Do not make any visual or gameplay changes. Preserve the current dirty worktree, run the baseline tests, create the visual-overhaul branch, checkpoint all current work, write docs/VISUAL_BASELINE.md, commit, and stop.
```
