#pragma once

#include "native_natural_terrain_source.hpp"
#include "native_terrain_shaping_snapshot.hpp"

namespace voxel::world_backend {

// Numeric terrain facts keep their source-coordinate remap explicit. The
// requested cell remains the edit key for lattice/surface projection calls;
// source_cell is the cell selected after Godot's float32 world-position
// round-trip and owns shaping/generated sampling.
struct NativeEffectiveNumericFacts {
    CellCoord requested_cell;
    CellCoord source_cell;
    double density = 0.0;
    bool underground_air_void = false;
    double surface_y = 0.0;
    TerrainMaterialId material = TerrainMaterialId::air;
    bool generated = true;
    bool edited = false;
};

// A cell state remains keyed by the requested integer coordinate for typed
// edit precedence and persistence. source_cell separately records the cell
// selected by the float32 center-position round trip for generated sampling.
struct NativeEffectiveCellStateFacts {
    CellCoord requested_cell;
    CellCoord source_cell;
    NativeCellState state;
};

// Surface projection uses `Vector3(float(cell) * s)`: one binary64 scalar
// product followed by Vector3's float32 storage boundary. It is not the
// two-float-boundary VoxelTerrainGenerator lattice convention.
struct NativeResolvedSurfaceProjectionQuery {
    CellCoord grid_cell;
    WorldFloat32Position position;
    WorldQueryIntent intent = WorldQueryIntent::terrain_collision;
};

NativeResolvedSurfaceProjectionQuery resolve_native_surface_projection_query(
    const WorldSourceDefinition &definition, const WorldLatticeQuery &query);

// Pure effective terrain resolver. It consumes one immutable page-scoped pin,
// never callbacks into GDScript, and deliberately does not inspect feature
// blocks: feature instances are not terrain cells.
class NativeEffectiveTerrainSource final {
public:
    explicit NativeEffectiveTerrainSource(WorldSourcePin pin);
    NativeEffectiveTerrainSource(const NativeEffectiveTerrainSource &) = delete;
    NativeEffectiveTerrainSource(NativeEffectiveTerrainSource &&) noexcept = default;
    NativeEffectiveTerrainSource &operator=(const NativeEffectiveTerrainSource &) = delete;
    NativeEffectiveTerrainSource &operator=(NativeEffectiveTerrainSource &&) = delete;

    const WorldSourcePin &pin() const noexcept;

    NativeSurfaceColumnFacts sample_surface_column(const WorldSurfaceColumnQuery &query) const;
    TerrainBiomeId sample_surface_biome(const WorldSurfaceColumnQuery &query) const;
    // TerrainVolumeService.column_top_surface_y_for_cell semantics: scan the
    // effective typed volume, including scene-overlay precedence, and return
    // the upper face of the highest solid cell. This is deliberately distinct
    // from the shaped/reference surface carried by sample_surface_column().
    double sample_volume_surface_y(const WorldSurfaceColumnQuery &query) const;
    NativeEffectiveCellStateFacts sample_cell_state_facts(const WorldCellCenterQuery &query) const;
    NativeCellState sample_cell_state(const WorldCellCenterQuery &query) const;

    // VoxelTerrainGenerator semantics: a durable edit is keyed by the original
    // integer lattice coordinate. Otherwise shaping/generation uses the
    // float32-remapped source coordinate. Scene overlays never enter this API.
    NativeEffectiveNumericFacts sample_lattice_numeric(const WorldLatticeQuery &query) const;

    // TerrainVolumeService.numeric_sample_world semantics: typed precedence is
    // resolved at the remapped world-position cell. A non-mesh overlay yields
    // canonical -CELL density rather than revealing the durable cell beneath.
    NativeEffectiveNumericFacts sample_world_numeric(WorldFloat32Position position) const;

    // WorldGenerationSystem.volume_surface_numeric_sample_at_grid_cell
    // semantics: the effective typed state is keyed by the original lattice
    // cell, but a non-surface-affecting overlay falls through to generation.
    NativeEffectiveNumericFacts sample_surface_projection_numeric(const WorldLatticeQuery &query) const;

private:
    struct GeneratedFacts;

    const NativeTerrainShapingSnapshot &shaping_for(std::int32_t x, std::int32_t z) const;
    double natural_surface(std::int32_t x, std::int32_t z) const;
    double shaped_surface(std::int32_t x, std::int32_t z) const;
    TerrainBiomeId shaped_surface_biome(std::int32_t x, std::int32_t z) const;
    GeneratedFacts generated_at(WorldFloat32Position position) const;
    NativeEffectiveNumericFacts generated_numeric(
        CellCoord requested_cell, WorldFloat32Position position,
        CellCoord material_cell, CellCoord biome_cell) const;
    NativeCellState sample_cell_state_in_pinned_page(const WorldCellCenterQuery &query) const;

    WorldSourcePin pin_;
    NativeNaturalTerrainSource natural_;
};

} // namespace voxel::world_backend
