# True 3D Cave Biome Implementation Plan

This is the controlling plan for replacing the current hybrid cave work. Read this file before every cave/world-generation edit. If any instruction here conflicts with older cave implementation notes, this file wins.

## Product Goal

Build a mature procedural world generator where caves are naturally occurring biomes inside one deterministic 3D world volume.

The world must be generated from authoritative `(x,y,z)` samples. Caves must not be inserted, patched, hidden, capped, rimmed, arched, or placed into an existing `(x,z)` terrain surface. A cave entrance is only the place where the cave biome/air volume intersects the terrain volume.

## Hard Requirements

- No authoritative `(x,z)` terrain generation remains. Final terrain, caves, materials, collision, props, and navigation must derive from `(x,y,z)` samples.
- Compatibility methods with `(x,z)` names may exist only as temporary adapters during migration, and only if their implementation immediately delegates to `(x,y,z)` volume sampling. They must not own terrain, cave, material, or biome decisions.
- Caves are a biome. Cave air, cave floor, cave wall, cave ceiling, cave material, and cave lighting/nav metadata must be consequences of world-volume biome/density samples.
- `StructureSystem` must not create cave terrain, cave mouths, cave portals, cave shell geometry, cave walls, cave floors, cave ceilings, or cave collision.
- `SubsurfaceSystem` must not patch terrain to make caves look open. It may become a player excavation/digging adapter only if it writes deterministic 3D volume edits.
- `CaveInteriorBuilder` must not build an alternate cave shell. Any cave formations or supports are decorations attached after the cave volume exists, not geometry authority.
- Mesh and collision must be extracted from the same volume source.
- Surface terrain mesh must be extracted from the same volume as cave interiors. A heightfield with hidden cave quads is not acceptable.
- The cave mouth must not be directly tuned as a separate feature. If the mouth looks wrong, fix the volume field, biome transition, terrain extraction, or meshing. Do not add a mouth prop, patch, cap, rim, facade, arch, or portal.
- Tests must fail if any cave acceptance depends on `(x,z)` terrain edits, hidden mouth quads, material overrides, inserted shell geometry, or StructureSystem cave placement.

## Drift Stop Conditions

Stop immediately and return to this plan if work starts to involve any of the following:

- Adjusting a cave mouth, entrance facade, portal, arch, cap, rim, or patch as its own feature.
- Adding or preserving a special-case terrain cut for caves outside the world-volume sampler.
- Treating cave generation as a StructureSystem placement problem.
- Making screenshots pass while volume, mesh, collision, and biome authority remain split.
- Adding tests that prove metadata while the visible world still uses a separate surface path.
- Keeping an `(x,z)` helper because it is convenient instead of removing it or proving it is a pure adapter.

## Target Architecture

### WorldGenerationSystem

`WorldGenerationSystem` is the only authority for natural world generation.

Required core API:

```gdscript
sample_cell(cell: Vector3i) -> Dictionary
sample_world(position: Vector3) -> Dictionary
density_at(position: Vector3) -> float
solid_at(position: Vector3) -> bool
biome_at(position: Vector3) -> String
material_at(position: Vector3) -> String
```

Each sample must be deterministic from seed and position. A sample includes at least:

- `density`: signed or thresholdable solid/air value.
- `solid`: whether the cell is solid.
- `biome`: including `"cave"` for cave air/interior volume.
- `material`: air, grass, dirt, stone, ore, cave wall material, etc.
- `surface`: whether this sample is near a visible solid/air boundary.

Height may be derived from volume for legacy callers during migration, but height must not be authoritative.

### Terrain And Chunk Meshing

`MainPlaytestTools.gd` / terrain chunk generation must move from heightfield meshing to volume surface extraction.

Acceptable approaches:

- continuous isosurface extraction from scalar density samples, such as marching tetrahedra, marching cubes, or dual contouring;
- greedy voxel meshing over solid/air samples only if it preserves the existing natural/stylized terrain silhouette.

The product target is not Minecraft-style terrain. Visible terrain must preserve the game's natural look while remaining derived from `(x,y,z)` samples. A literal exposed-cube face extractor is allowed only as a temporary debugging tool and must not be accepted as the shipping terrain renderer.

For this game, the exterior terrain skin may be emitted as a natural projected surface only if that projection is derived from the authoritative 3D solid/air boundary. Cave and subsurface void boundaries must still be emitted from the same density/biome volume into the same chunk mesh and collision asset. This is not permission to restore an `(x,z)` terrain authority.

The chunk mesher must:

- sample `(x,y,z)` volume cells across a bounded chunk volume;
- emit surfaces only where the volume crosses the solid/air boundary;
- allow a smooth exterior projection only as a derived presentation of that boundary, never as generation authority;
- assign material/biome color from the solid sample adjacent to air;
- build collision from the same emitted geometry or the same solid/air sample set;
- include cave interior, cave mouth, hill exterior, overhangs, and ordinary terrain in one extraction path.

### Caves As Biome Field

Caves are generated as part of the 3D biome/density field.

Allowed:

- deterministic cave noise fields;
- deterministic cave tunnel/chamber feature fields owned by `WorldGenerationSystem`;
- cave region descriptors inside world generation if they produce density/biome samples directly.

Not allowed:

- StructureSystem cave plans as terrain authority;
- `apply_cave_terrain_edits`;
- hidden terrain quads as cave mouth authority;
- stone material overrides for cave portals;
- an interior shell mesh independent from terrain mesh;
- a separate mouth model or entrance prop.

A cave feature graph may exist only as an internal density generator in `WorldGenerationSystem`. It must answer the question "what is the density/biome at this `(x,y,z)`?" It must not place a cave into terrain after terrain exists.

### Decoration After Volume

Systems may decorate caves only after the cave biome volume exists.

Examples:

- torches/supports placed on cave wall samples;
- loot chests placed in cave biome chambers;
- ore formations attached to cave wall/floor samples;
- navigation records derived from traversable cave air samples.

Decoration must not create the cave. Removing all cave decoration must still leave a naturally carved cave biome in terrain.

## Migration Phases

### Phase 0: Audit And Freeze Hybrid Behavior

Goal: identify all remaining `(x,z)` world authority and cave-placement code.

Tasks:

- Inventory all generation functions with `(x,z)` signatures.
- Classify each as `delete`, `temporary adapter`, or `non-generation utility`.
- Inventory all cave-specific terrain edits, hidden quads, material overrides, shell builders, portal/mouth metadata, and StructureSystem cave plan authority.
- Add a temporary static audit report listing every known offender.

Exit criteria:

- A file-level offender list exists.
- No implementation begins until each offender has a migration target.

### Phase 1: Authoritative Volume Sampling

Goal: make one 3D sampler capable of answering all world questions.

Tasks:

- Define and implement the sample API in `WorldGenerationSystem`.
- Move surface terrain density into the sampler.
- Move cave biome/density generation into the sampler.
- Move material selection into the sampler.
- Move excavation edits into 3D volume edit samples.
- Preserve seed determinism.

Exit criteria:

- Unit/contract tests prove `solid`, `biome`, and `material` are stable for fixed `(seed,x,y,z)`.
- Cave biome samples exist without calling `StructureSystem.build_cave`.
- No cave sample depends on terrain patch maps.

### Phase 2: Volume Terrain Meshing

Goal: replace heightfield terrain rendering with volume surface extraction.

Tasks:

- Replace chunk heightfield mesh generation with 3D solid/air surface extraction.
- Generate terrain collision from the same extracted volume geometry.
- Support ordinary terrain, hills, caves, cave mouths, and overhangs in the same chunk mesh.
- Remove hidden cave quad logic from the terrain render path.
- Remove stone/material cave portal override logic.

Exit criteria:

- A chunk containing a cave mouth renders from the same mesher as a chunk with no cave.
- Mesh and collision share the same volume source.
- Disabling cave decoration does not remove cave geometry.
- Tests fail if terrain mesh generation calls cave patch/portal code.

### Phase 3: Remove StructureSystem Cave Authority

Goal: StructureSystem stops generating caves.

Tasks:

- Delete or neutralize `apply_cave_terrain_edits`.
- Remove StructureSystem cave mouth, opening, portal, wall, floor, ceiling, and terrain patch logic.
- Replace cave generation calls with cave biome discovery queries against `WorldGenerationSystem`.
- Let StructureSystem decorate existing cave regions only after querying the volume.

Exit criteria:

- `StructureSystem` cannot create a cave if the world sampler has no cave biome there.
- Cave tests still find cave biome volumes before any decoration.
- Static tests fail on StructureSystem cave terrain-authority functions.

### Phase 4: Remove Shell Authority

Goal: no independent cave shell remains.

Tasks:

- Delete `CaveInteriorBuilder.build` as geometry authority.
- Keep only optional decoration helpers that sample cave volume surfaces.
- Remove any cave mesh named or treated as an interior shell unless it is the chunk volume mesh itself.
- Ensure cave collision bodies are not separately generated from a shell.

Exit criteria:

- Tests fail if a cave acceptance requires `interior_shell`.
- Tests pass with cave decorations disabled and world volume still visible/passable.

### Phase 5: Delete `(x,z)` Generation

Goal: finish removing all 2D generation authority globally, not just caves.

Tasks:

- Delete or adapter-only migrate `height_at_world`, `terrain_height_cell`, `base_height_cell`, `natural_base_height_cell`, and `biome_at_cell`.
- Replace prop placement, biome lookup, navigation, spawn placement, and gameplay ground checks with `(x,y,z)` volume queries.
- Keep chunk coordinates as 2D indexing only. Chunk indexing may be `(chunk_x, chunk_z)`, but generation inside chunks must be 3D.

Exit criteria:

- Static tests fail if banned `(x,z)` generation functions contain non-adapter logic.
- All generation decisions use `Vector3`, `Vector3i`, or equivalent 3D sample data.
- Any remaining `(x,z)` usage is documented as indexing/projection only, not generation authority.

### Phase 6: Acceptance Tests

Goal: make regressions impossible to hide.

Required tests:

- Static audit: fail on cave terrain patch functions, hidden portal cells, material portal overrides, cave shell authority, and StructureSystem cave terrain authority.
- Static audit: fail on non-adapter `(x,z)` generation functions.
- Determinism: same seed and `(x,y,z)` sample returns same solid/biome/material.
- Biome contract: cave air samples return biome `"cave"` before decoration.
- Terrain contract: terrain mesh faces only appear at solid/air transitions from volume samples.
- Terrain style contract: tests/static audit must fail if the accepted terrain renderer regresses to visible cube-face voxel terrain.
- Collision contract: collision and mesh are generated from the same volume extraction source.
- Decoration contract: removing cave decorations does not remove cave volume, cave mouth, cave tunnel, or cave collision.
- Visual acceptance: headed screenshots and ray checks must fail for:
  - visible wall across the cave entrance;
  - passable visual wall;
  - blocked visual opening;
  - top hole in mound/terrain;
  - rectangular inserted portal look caused by a separate cut;
  - cave entrance larger than containing terrain volume.
- Screenshot inspection remains required until automated visual classification is strong enough to catch the above failures.

## Banned Success Claims

Do not claim cave success from any of these alone:

- metadata says cave exists;
- StructureSystem has a cave record;
- hidden portal cells are present;
- material override cells are absent;
- a cave shell mesh exists;
- collision exists independently of terrain volume;
- ray checks pass while screenshots still show an inserted rectangular mouth;
- tests pass but the implementation still depends on `(x,z)` heightfield terrain.

## Definition Of Done

This work is done only when all are true:

- The natural world is generated from `(x,y,z)` solid/air/biome/material samples.
- Caves are generated as cave biome/air regions in that same world volume.
- Terrain exterior, cave entrance, tunnel, chamber, floor, ceiling, walls, mesh, and collision come from one volume extraction path.
- No cave mouth-specific patch, prop, arch, cap, rim, facade, terrain edit, material override, or hidden-quad authority remains.
- StructureSystem decorates caves but cannot create cave geometry.
- Tests fail for any return to `(x,z)` generation authority.
- Tests fail for any return to cave-as-placed-structure architecture.
- Headed visual screenshots are manually inspected and do not show an inserted cave mouth, blocked entrance, passable visual wall, or top hole.

## Working Rule

If the next change is not moving world generation toward this architecture, do not make it.
