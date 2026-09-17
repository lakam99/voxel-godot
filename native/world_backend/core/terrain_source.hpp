#pragma once

#include "terrain_snapshot.hpp"

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

struct TerrainDeltaState {
    double density = -1.35;
    bool solid = false;
    TerrainMaterialId material = TerrainMaterialId::air;
    TerrainBiomeId resolved_biome = TerrainBiomeId::underground_air;
    TerrainFluidId fluid = TerrainFluidId::none;

    bool operator==(const TerrainDeltaState &other) const noexcept;
};

struct TerrainDelta {
    std::string id;
    std::uint64_t revision = 0;
    CellCoord coordinate;
    TerrainDeltaState state;

    bool operator==(const TerrainDelta &other) const noexcept;
};

std::vector<std::uint8_t> serialize_terrain_deltas(const std::vector<TerrainDelta> &deltas);
std::vector<TerrainDelta> deserialize_terrain_deltas(const std::vector<std::uint8_t> &bytes);

// Pure legacy rules are public so the bounded N2 source and focused tests use
// one implementation without broadening the accepted N2 seed/region.
double terrain_smoothstep(double value, double low, double high) noexcept;
TerrainBiomeId terrain_biome_for_climate(double temperature, double moisture) noexcept;
TerrainBiomeId terrain_surface_biome_for_height(
    double height, TerrainBiomeId regional_biome) noexcept;
double terrain_apply_world_floor_density(double position_y, double density) noexcept;
double terrain_apply_underground_floor_density(double position_y, double density) noexcept;
TerrainMaterialId terrain_solid_material(
    const std::string &seed,
    const CellCoord &cell,
    double surface_y,
    double position_y,
    TerrainBiomeId biome,
    double density);

struct TerrainSourceRequest {
    std::string seed_text;
    std::vector<std::uint32_t> seed_code_points;
    RequestAuthority authority;
    std::string transaction_id;
    CellRegion sample_region;
    std::vector<TerrainDelta> deltas;
    std::vector<DeclaredFeatureBlocker> blockers;
};

class TerrainSourceRejected final : public std::runtime_error {
public:
    explicit TerrainSourceRejected(AuthorityDecision decision);
    AuthorityDecision decision() const noexcept;
private:
    AuthorityDecision decision_;
};

CellRegion n2_combined_sample_region() noexcept;
DeclaredFeatureBlocker n2_declared_feature_blocker();
std::vector<std::uint32_t> atlas_1492_code_points();

TerrainSourceRequest n2_terrain_source_request(
    const RequestAuthority &authority,
    std::string transaction_id,
    std::vector<TerrainDelta> deltas = {});

// This N2 source is deliberately bounded to the frozen atlas-1492 combined
// sample region. It computes the real lattice-origin generator rules for every
// sample, then resolves typed deltas; it is not a fixture lookup table.
TerrainSnapshot build_terrain_snapshot(
    const TerrainSourceRequest &request,
    const RequestAuthority &current_authority);

} // namespace voxel::world_backend
