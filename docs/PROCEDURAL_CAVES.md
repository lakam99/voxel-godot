# Procedural caves

## Authority and generation

`WorldGenerationSystem` composes `world/ProceduralCaveField.gd` into the same
signed density consumed by terrain volume and `VoxelTerrainGenerator`.
Transvoxel remains the smooth renderer/collider. There are no cave meshes,
entrance wrappers, teleport entrances, or cave-specific collision substitutes.

The field combines independent noise chambers and intersecting noise passages
below roughly 30 metres of overburden with regional tunnel carvers. Accepted
regional recipes provide a surface approach, a chamber, four descending loop
tiers, and two cross-tier links on alternating trunk edges. This creates deep,
multi-route cave networks rather than a single descending passage. Rounded
passage cross-sections have broad floors; chamber unions blend to avoid sharp
junction saddles. Recipes can produce additional surface openings where their
volume intersects terrain. A cave is not guaranteed in every region or
connected to every other cave.

The 192-metre recipe regions use their own seed-derived RNG. They do not consume
terrain, town, or prop RNG. Recipes fit inside their source region; a bounded
cache changes query cost, not results. Generation rejects unsuitable terrain and
conservatively excludes the exact town footprint plus its terrain apron. Deeper
noise remains beneath the surface; bedrock remains solid.

Carving is composed on both sides of the surface boundary. Clipping a cave SDF
to positive heightfield density creates incorrect negative interpolation values
and false entrance lips, even when discrete solid/air signs look plausible.

Entrance-connected carvers are dry through the existing fluid query. Other
underground spaces retain ordinary aquifer/lava policy. Materials, ores, edits,
lighting state and save deltas continue through the existing volume service.
Generated recipes are not serialized as player edits. This intentionally changes
generated underground geometry for existing seeds; save version remains 2.

## Grounding and ecology

The underground support facade samples the volume lattice at actual XZ and
interpolates its floor crossing. It no longer treats a solid lattice sample as
a cube whose top is one full cell higher. Its search begins below player head
height, and edited cells use the existing volume data. The outer facade no
longer gates this query with a nearest-cell air test or an edited-column shortcut.
The protected character motor, NPC routes and navigation publication are unchanged.

Surface prop spawning checks nearby cave bounds, then center/cardinal ground
support samples over a 1.5-metre footprint. It rejects carved support instead of
spawning from the pre-carving height alone. This is conservative sampling, not
an exact test of every possible mature tree's entire mesh footprint.

Lighting is polish layered over the authoritative cave volume. Cave material
colors should remain natural and muted; they must not be tinted green to improve
torch visibility. The held torch is the primary carried light source. This
document does not claim that every local source casts real-time shadows.

## Verification entry points

From the project root, use the bundled Godot console executable:

```powershell
$godot = 'C:/Users/arkam/Desktop/Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe'
& $godot --headless --path . --script res://scripts/testing/terrain/CaveGenerationContractRunner.gd
& $godot --headless --path . --script res://scripts/testing/terrain/CaveAuthorityContractRunner.gd
& $godot --path . --script res://scripts/testing/terrain/CaveWalkthroughRunner.gd
```

The generation runner checks sampled body clearance and resulting floor grades
along entrance, loop, deep routes and tier links. Its full prevalence sample
uses 10 stable seeds across 81 regions per seed (6.1 km square). A “substantial
network” means at least four depth loops and 60 metres of vertical travel; the
sampled-region gate requires at least 50% prevalence per seed. This is a
deterministic contract sample, not proof about every possible seed. The authority runner
compares encoded worker SDF values, exercises cache eviction/reversed queries,
and checks direct-service edit serialization. These are contract/service
evidence, not substitutes for gameplay.

The walkthrough normally launches Main Menu and clicks New Game. New Game may
choose a different seed; the report records the actual one. Fixture setup places
the production player once outside a generated entrance and supplies an ordinary
torch. After that, movement is ordinary player input with physics and terrain
readiness intact. Arrivals require the intended elevation, a floor ray and the
capsule's real walkable floor contact. Sidesteps/jumps are input, not transforms.
Reports include screenshots, positions/input, collider/support observations,
and a coordinate-matched volume/collision audit of selected view rays.

`CAVE_DIAGNOSTIC=1` enables the existing visual fast boot and is explicitly
reported as diagnostic. `CAVE_SEED`, `CAVE_REGION_X`, `CAVE_REGION_Z` select a
diagnostic replay. `CAVE_OUTPUT` selects an isolated artifact/save directory.
`CAVE_RECORD=1` saves actual rendered JPEG frames and a timestamped FFmpeg concat
manifest. Recording and diagnostic ray-audit overhead must not be described as
ordinary runtime performance. No generated images are used as game evidence.

For normal streaming/performance, use the existing
`tools/run-normal-runtime-performance-pass.ps1` with no fast-boot flags. Distinguish
main-loop timings, physics/render intervals, startup, and worker generation cost.

The independent visual critic's reviews and run artifacts live under
`artifacts/caves/`. Screenshots and a walkthrough video are required to judge
the scale, connectivity cues and natural muted palette. A failed automated
player traversal is a playtest-logic issue unless a cave-generation or real
navigation defect is demonstrated; the user may perform final traversal
verification in-game. Historical failed captures remain evidence, not passing
acceptance.
