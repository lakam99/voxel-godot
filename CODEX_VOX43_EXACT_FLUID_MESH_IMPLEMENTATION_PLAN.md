# VOX-43 Exact Fluid Mesh Implementation Plan

## Status And Authority

This document is the controlling sequential implementation plan for Linear issue `VOX-43`, "Terrain ground renders translucent in forest and savanna."

Follow the phases in order. A phase is complete only when all of its exit requirements and evidence requirements are satisfied. Do not start later-phase implementation while an earlier phase is failing, ambiguous, or incomplete.

This plan repairs the translucent fluid overlay. It does not authorize a broad terrain rewrite, an unrelated pathfinding change, or a visual workaround.

## Goal

Render generated water and lava from exact authoritative terrain-volume cells without allowing terrain mesh LOD to enlarge categorical fluid occupancy.

The player must never see an underground aquifer sample expanded into a coarse transparent cube above or through surface terrain.

## Confirmed Root Cause

The defect is proven in the normal runtime on seed `atlas-71906947`:

- Node: `/root/MainMenu/Main/Chunks/Chunk_11_1/TerrainFluidMesh`
- Backend: `native_volume_mesher`
- `nativeFluidStepCells=14`
- Fluid faces: `6`, representing one complete cube
- Cube dimensions: `18.9 x 18.9 x 18.9` world meters
- Cube vertical span: `y=2.7..21.6`
- Water shader: `res://shaders/stylized_water.gdshader`
- Shader alpha: `0.78..0.95`
- Global surface-water mesh at the location: zero surfaces

Hiding `TerrainFluidMesh` removes the translucent block. Hiding global `Water` does not.

Evidence:

- `artifacts/vox43-root-cause/render-isolation-report.json`
- `artifacts/vox43-root-cause/captures/yaw_225_all_visible.png`
- `artifacts/vox43-root-cause/captures/yaw_225_chunk_fluid_hidden.png`
- `artifacts/vox43-root-cause/town-neighborhood-fluid-map.json`
- `artifacts/vox43-root-cause/underground-fluid-render-contract.json`

The causal code path is:

1. `scripts/MainPlaytestTools.gd` chooses terrain volume step `14` for ordinary unedited generated-volume chunks.
2. `scripts/TerrainVolumeService.gd` creates one sparse payload at that same step.
3. `native/terrain_meshing/src/terrain_meshing_backend.cpp` uses the payload step for both smooth terrain density and categorical fluid occupancy.
4. One sampled aquifer cell is emitted as a full `14 x 14 x 14` cell water cube.

## Mandatory Invariants

These invariants apply to every phase and every implementation choice:

1. `TerrainVolumeService` remains the authority for solid state, material, biome, fluid, and light.
2. Smooth terrain may use LOD-dependent density sampling.
3. Fluid occupancy must use exact cells at `fluidStepCells=1`.
4. A fluid vertex must be attributable to a boundary of an authoritative fluid cell.
5. A coarse terrain job must never emit a coarse fluid placeholder.
6. Neighbor state for face culling must come from a one-cell halo, including across chunk boundaries.
7. Native mesh work remains asynchronous and budgeted during gameplay.
8. Worker code prepares immutable data and CPU mesh arrays. Active scene-tree mutation remains on the main thread.
9. Global surface water remains behaviorally unchanged.
10. Water and lava remain real terrain fluid states. They must not be hidden or deleted to make the test pass.
11. Existing saves remain loadable without destructive migration.
12. The known seed is regression evidence, not a production special case.

## Prohibited Shortcuts

The following do not satisfy this plan:

- making the water shader opaque;
- lowering alpha until the defect is less visible;
- hiding all `TerrainFluidMesh` nodes;
- disabling aquifer generation;
- clamping fluid geometry to a guessed terrain surface;
- deleting fluid faces above a hard-coded world height;
- special-casing seed `atlas-71906947`, chunk `11,1`, or a named biome;
- changing terrain step `14` to `7` and retaining sampled fluid expansion;
- forcing all terrain meshing to step `1`;
- adding visual skirts, shells, caps, or overlay geometry;
- accepting metadata without headed screenshot inspection;
- accepting a test-only mode that renders fluids differently from normal gameplay;
- weakening existing underground fluid tests;
- fixing the separate solid-terrain LOD problem inside this task without an explicit scope decision.

## Linear Tracking Protocol

Before Phase 1 implementation, create these child issues under `VOX-43`:

1. `Install exact-fluid regression gate`
2. `Add exact fluid payload snapshot`
3. `Replace native coarse fluid extraction`
4. `Integrate exact fluid mesh into async runtime`
5. `Verify real boot and generated-world fluid rendering`

Only one child issue may be In Progress at a time. Complete a child issue immediately when its phase exit gate is satisfied. Keep `VOX-43` In Progress until every phase is complete.

Every Linear completion comment must include:

- commit;
- commands;
- report paths;
- screenshot paths when visual behavior is involved;
- what the evidence proves;
- what the evidence does not prove.

## Branch And Commit Protocol

1. Preserve the existing dirty worktree.
2. Use a focused `codex/vox-43-exact-fluid-mesh` implementation branch unless the user directs otherwise.
3. Do not include unrelated line-ending changes or user work.
4. Commit after each completed phase.
5. Do not call a phase complete while required evidence is missing.

## Phase 1: Install A Failing Regression Gate

### Objective

Encode the confirmed defect before changing production behavior.

### Required Work

Add a focused exact-fluid contract runner and PowerShell wrapper. The runner must build fluid geometry through the real production payload/native backend contract.

At minimum, cover:

1. One water cell with air above and around it.
2. Two adjacent cells of the same fluid.
3. A fluid cell next to opaque solid terrain.
4. Fluid cells crossing a chunk boundary.
5. Water and lava in the same test region.
6. The known `atlas-71906947` cell represented by the broken runtime cube.

### Initial Failure Requirements

The pre-fix test must fail because:

- metadata reports `nativeFluidStepCells=14`, or
- geometry extends beyond exact fluid-cell bounds, or
- the known aquifer sample produces the `18.9m` cube.

The test must not fail because of fixture setup, missing DLLs, parse errors, or timeouts.

### Required Assertions

- A cell at grid `y=2` may produce vertices only from world `y=2.7` through `y=4.05`.
- Every face lies on an exact cell boundary.
- Same-fluid internal faces are absent.
- A solid-adjacent fluid face is absent.
- Cross-chunk internal faces are absent.
- Water and lava use separate surfaces/material identities.

### Exit Gate

- The new runner compiles.
- The runner fails for the confirmed production defect.
- Failure output names the invalid step and invalid geometry bounds.
- Existing fluid and terrain contracts remain unchanged and still run.
- The Linear child is completed with the failing report attached or referenced.

Stop if the test cannot reproduce the invalid cube. Do not modify production code until reproduction is deterministic.

## Phase 2: Add An Exact Fluid Payload Snapshot

### Objective

Separate continuous terrain-density LOD from categorical fluid occupancy without changing rendering yet.

### Payload Contract

Retain the existing terrain payload fields for compatibility, but make the distinction explicit:

```text
terrainStepCells: LOD-dependent
fluidPayload:
  schemaVersion: 1
  stepCells: 1
  minCell: chunk minimum minus one-cell halo
  maxCell: chunk maximum plus one-cell halo
  revision: authoritative terrain-volume revision
  sections/cells: immutable exact solid and fluid occupancy
```

The exact payload should contain only data required by fluid extraction:

- solid occupancy;
- numeric fluid type (`none`, `water`, `lava`);
- coordinates or section-local indices;
- one-cell halo data.

Do not copy biome, color, light, material strings, or density into this payload unless a verified fluid requirement needs them.

### Required Work

1. Add an exact snapshot API to `TerrainVolumeService`.
2. Source it from authoritative 16-cubed section channels.
3. Make the snapshot immutable for the lifetime of a worker job.
4. Include section and fluid revisions in cache/job signatures.
5. Support cancellation and stale-result rejection using the existing job signature model.
6. Skip payload construction when authoritative sections contain no fluid in the requested bounds.
7. Keep payload creation budgeted. Do not synchronously scan an unbounded world volume.

### Exit Gate

- Contract tests prove exact cell and halo contents.
- Cross-boundary neighbor state is present.
- A terrain step of `14` still produces a fluid payload step of `1`.
- Save-loaded edits are reflected in the payload revision.
- No rendering behavior has been doctored.
- Compile smoke and terrain-volume contracts pass.
- The Linear child is completed with reports and commit.

Stop if exact payload construction causes an unbounded synchronous frame stall. Profile and correct payload ownership/budgeting before continuing.

## Phase 3: Replace Native Coarse Fluid Extraction

### Objective

Make the native backend produce fluid surfaces exclusively from exact occupancy.

### Required Native Behavior

For every exact fluid cell:

1. Same fluid in neighbor: emit no face.
2. Opaque solid in neighbor: emit no fluid face; terrain owns that boundary.
3. Air in neighbor: emit one cell-sized face.
4. Different fluid in neighbor: emit the legal interface according to deterministic fluid ordering.
5. Unknown neighbor: invalid input. The halo contract must prevent this state.

Aggregate all water faces into one surface and all lava faces into one surface per runtime fluid mesh.

### Required Metadata

- `terrainMeshingBackend=native_volume_mesher`
- `terrainFluidSectionPayload=true`
- `nativeFluidStepCells=1`
- exact fluid-cell count;
- emitted water/lava face counts;
- payload revision.

### Compatibility Behavior

If the backend receives only the old coarse payload:

- return an empty/deferred fluid result with explicit metadata;
- do not build a coarse cube;
- do not silently reinterpret `terrainStepCells` as fluid occupancy resolution.

### Build And Test Commands

```powershell
.\tools\build-native-terrain-meshing.ps1
.\tools\run-underground-fluid-render-tests.ps1 -Seed atlas-71906947
.\tools\run-underground-volume-audit.ps1
.\tools\run-project-compile-smoke.ps1
```

Add the new exact-fluid contract command to this list once its wrapper exists.

### Exit Gate

- The Phase 1 regression changes from failing to passing.
- The known cell produces no vertex outside one-cell bounds.
- Same-fluid, solid-neighbor, and cross-chunk face assertions pass.
- Native debug and release libraries build successfully.
- Existing underground fluid behavior remains present.
- The Linear child is completed with reports and commit.

Stop if the solution only passes through GDScript fallback. Production native behavior is mandatory.

## Phase 4: Integrate Exact Fluid Meshes Into Async Runtime

### Objective

Route normal chunk streaming through the exact fluid payload and native extraction without reintroducing frame spikes or placeholders.

### Required Runtime Behavior

1. Terrain and exact fluid payloads may be prepared in one coordinated job, but retain separate step contracts.
2. Worker code builds immutable mesh arrays/resources only.
3. Main thread applies `TerrainMesh` and `TerrainFluidMesh` nodes.
4. New chunks show no underground fluid while exact fluid data is pending.
5. A prior exact fluid mesh may remain visible only if its revision still matches.
6. Stale or cancelled jobs cannot replace a newer mesh.
7. Fluid edits invalidate affected sections/chunks and their one-cell neighbors.
8. No collision is added to `TerrainFluidMesh` unless a separate gameplay requirement explicitly introduces it.
9. Global `Water` remains unchanged.

### Instrumentation

Add bounded counters for:

- exact fluid payload cells/sections;
- fluid jobs queued/completed/dropped;
- exact water/lava faces;
- fluid payload and native mesh build duration;
- stale fluid result rejection;
- forbidden coarse fluid payload attempts.

Do not retain noisy per-cell logging.

### Exit Gate

- Normal runtime reports `nativeFluidStepCells=1` for generated aquifers.
- No runtime path emits a `TerrainFluidMesh` at step greater than `1`.
- Streaming, cancellation, save load, and edit refresh tests pass.
- Runtime performance observation shows no new frame over the existing `33ms` spike threshold attributable to this work.
- The Linear child is completed with reports and commit.

Stop if the implementation fixes screenshots by globally suppressing fluid meshes. Underground visibility must still be proven in Phase 5.

## Phase 5: Real Gameplay And Visual Acceptance

### Objective

Prove the fix in normal gameplay and prove that real aquifers still render underground.

### Known Save Acceptance

Use an isolated copy of the real `atlas-71906947` save.

Launch the normal headed executable:

```powershell
& "C:\Users\arkam\Downloads\Godot_v4.6.1-stable_win64.exe\Godot_v4.6.1-stable_win64.exe" --path "C:\Users\arkam\Documents\Codex\2026-06-18\goal-develop-a-3d-voxel-seed\outputs\voxel-biome-world-godot"
```

Requirements:

- physically select `Continue` from the main menu;
- `VOXEL_PLAYTEST`, `VOXEL_TEST_SEED`, and god mode must be unset;
- a save-path override may point only to the byte-equivalent isolated save copy;
- traverse the affected forest and savanna through real player movement;
- inspect screenshots at the original failure area;
- verify no transparent aquifer cube intersects surface terrain.

### Underground Preservation Acceptance

- Locate a generated aquifer through authoritative terrain-volume state.
- Reach or observe it through a real generated cave/underground fixture.
- Verify water remains visible where exposed to air.
- Verify water does not render through enclosing solid terrain.
- Verify water/lava materials remain correct.

### Fresh World Coverage

Run multiple fresh random worlds. At minimum:

- one forest traversal;
- one savanna traversal;
- one surface cave entrance;
- one underground aquifer observation;
- one chunk-boundary fluid case.

### Required Commands

```powershell
.\tools\run-project-compile-smoke.ps1
.\tools\run-underground-fluid-render-tests.ps1 -Seed atlas-71906947
.\tools\run-underground-visual-playtest.ps1
.\tools\run-town-ground-visual-playtest.ps1 -Seed atlas-71906947
.\tools\run-runtime-performance-observation.ps1
.\tools\run-playtest.ps1
```

Add and run the exact-fluid contract and known-save headed wrapper created by this work.

### Visual Evidence Requirements

For every headed acceptance claim, report:

- exact command;
- seed/save identity;
- environment-flag proof;
- report path;
- screenshot paths;
- fluid mesh metadata;
- explicit statement of what the run proves and does not prove.

### Exit Gate

- Known-save translucent overlay is absent.
- Generated underground fluids remain visible and correctly bounded.
- No fluid mesh reports step greater than `1`.
- Cross-chunk seams are absent.
- Compile, contract, broad functional, visual, and performance gates pass.
- Screenshots are manually inspected.
- The Linear child is completed with reports and commit.

## Phase 6: VOX-43 Closure And Related Terrain Handoff

### Objective

Close only the proven translucent-fluid defect and preserve a clear boundary for remaining solid-terrain problems.

### Required Closure Audit

1. Re-run the known-save proof from a clean process.
2. Confirm the implementation branch diff contains no shader-opacity workaround or seed special case.
3. Confirm all five Linear child issues are Done.
4. Confirm `VOX-43` contains final commands, evidence, screenshots, and commit.
5. Mark `VOX-43` Done only after the real gameplay visual gate passes.

### Related But Separate Defect

The investigation also found:

- `42/49` nearby chunks classified as generated surface-volume exposure;
- coarse solid volume geometry, slabs, holes, and mixed LOD transitions;
- a visual runner that previously accepted provisional geometry after final native completion failed.

These findings must be tracked separately if they remain after exact fluid repair. Do not keep `VOX-43` open for unrelated solid-terrain work once the translucent overlay acceptance criteria pass, but do not declare the screenshots fully repaired if opaque slabs/holes remain untracked.

## Definition Of Done

`VOX-43` is complete only when all statements below are true:

- Fluid occupancy is meshed from exact authoritative cells.
- `nativeFluidStepCells` is always `1` for production fluid meshes.
- No coarse terrain sample can create a coarse fluid cube.
- No fluid vertex exceeds its owning exact-cell boundary.
- Neighbor and chunk-boundary face culling are deterministic.
- Normal menu-to-Continue gameplay no longer shows translucent forest/savanna ground.
- Underground aquifers and lava still render where genuinely exposed.
- Global surface water is unchanged.
- Existing saves load.
- Broad functional and performance gates pass.
- Required screenshots have been manually inspected.
- Linear phase items and `VOX-43` are updated truthfully.

## External Engineering References

- Godot thread safety and main-thread scene mutation: https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html
- Voxel Tools fluid modeling from per-voxel state: https://voxel-tools.readthedocs.io/en/latest/blocky_terrain/
- Voxel mesher neighbor padding for face culling: https://voxel-tools.readthedocs.io/en/latest/api/VoxelMesher/
- Voxel Tools smooth-terrain LOD context: https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/
