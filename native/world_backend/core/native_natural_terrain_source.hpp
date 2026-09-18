#pragma once

#include "native_cell_state.hpp"
#include "world_source.hpp"

#include <cstdint>
#include <stdexcept>

namespace voxel::world_backend {

// This initial N3 kernel accepts natural terrain only.  The production source
// can shape a column through a generated town or BuildingTerrainProfile;
// sampling natural terrain in their presence would be a second authority.
enum class NativeTerrainShapingInput : std::uint8_t {
    declared_absent = 0,
    generated_town_profiles_present = 1,
    generated_site_profiles_present = 2,
};

struct NativeNaturalTerrainRequest {
    NativeTerrainShapingInput shaping_input = NativeTerrainShapingInput::declared_absent;
};

class NativeNaturalTerrainUnsupported final : public std::runtime_error {
public:
    explicit NativeNaturalTerrainUnsupported(NativeTerrainShapingInput input);
    NativeTerrainShapingInput input() const noexcept;
private:
    NativeTerrainShapingInput input_;
};

// Pure natural-terrain sampler: it consumes the immutable WorldSource
// definition and does not callback into GDScript or carry a fallback source.
class NativeNaturalTerrainSource final {
public:
    NativeNaturalTerrainSource(WorldSourceDefinition definition, NativeNaturalTerrainRequest request = {});
    NativeNaturalTerrainSource(const NativeNaturalTerrainSource &) = delete;
    NativeNaturalTerrainSource(NativeNaturalTerrainSource &&) noexcept = default;
    NativeNaturalTerrainSource &operator=(const NativeNaturalTerrainSource &) = delete;
    NativeNaturalTerrainSource &operator=(NativeNaturalTerrainSource &&) = delete;

    const WorldSourceDefinition &definition() const noexcept;
    NativeSurfaceColumnFacts sample_surface_column(const WorldSurfaceColumnQuery &query) const;
    TerrainBiomeId sample_surface_biome(const WorldSurfaceColumnQuery &query) const;
    NativeLatticeNumericFacts sample_lattice_numeric(const WorldLatticeQuery &query) const;
    NativeCellState sample_cell_state(const WorldCellCenterQuery &query) const;

private:
    struct GeneratedSample;
    GeneratedSample sample_generated_at_position(
        const WorldFloat32Position &position, const CellCoord &numeric_coordinate) const;
    double natural_surface_y(std::int32_t x, std::int32_t z) const;
    TerrainBiomeId natural_surface_biome(std::int32_t x, std::int32_t z) const;
    double underground_air_density(
        const WorldFloat32Position &position, const CellCoord &source_cell, double base_surface_y,
        double depth_cells) const;

    WorldSourceDefinition definition_;
    std::uint32_t seed_hash_ = 0;
};

} // namespace voxel::world_backend
