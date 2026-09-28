# Kilometre Biome Field

`WorldGenerationSystem.surface_biome_for_cell3` is the sole gameplay authority
for surface biome selection. It composes one pure `BiomeRegionField`; there is
no alternate field, save-selected sampler, terrain path, or chunk-generation
path.

## Region contract

- One deterministically jittered site occupies each 6 km global-coordinate
  lattice cell.
- Site jitter is bounded to 320 m. Adjacent site centres therefore remain at
  least 5.36 km apart, yielding a stable core at least 5.36 km wide for every
  region before its 320 m ecotone.
- Climate is sampled once per region from deterministic broad temperature and
  moisture channels. A region then selects one macrobiome for all regular
  terrain within its Voronoi cell.
- Ocean and beach remain terrain-height decisions, and the tutorial town
  override remains unchanged.
- The field has no SceneTree state, per-chunk ownership, or mutable RNG.
  Sampling depends only on the world seed and global X/Z coordinates.

## Save authority

The save format is version 2. It contains no biome-field selector because the
regional field is unconditional. Version-1 and malformed local save payloads
are purged when `SaveSystem` opens its save path, including obsolete slot files
and their active-save marker. This is intentionally a breaking change: old
worlds are not migrated or replayed through a second biome authority.

## Verification

The focused contract runner proves repeatability, 2 km core probes, 24 km
cardinal/diagonal transects, bounded ecotone output, and removal of incompatible
saves. The normal gameplay suite additionally proves that save/load has no
biome selector and preserves the same regional query. The world-signature
baseline was regenerated only after two byte-identical regional-field signature
runs for `atlas-1492`.
