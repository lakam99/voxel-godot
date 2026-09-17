#pragma once

#include "authority.hpp"
#include "world_identity.hpp"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace voxel::world_backend {

enum class TerrainMaterialId : std::uint8_t {
    air = 0,
    grass = 1,
    dirt = 2,
    stone = 3,
    sand = 4,
    snow = 5,
    deep_stone = 6,
    bedrock = 7,
    clay = 8,
    gravel = 9,
    coal_ore = 10,
    iron_ore = 11,
    crystal_ore = 12,
    copper_ore = 13,
    mud = 14,
    water = 15,
};

enum class TerrainBiomeId : std::uint8_t {
    plains = 0,
    forest = 1,
    swamp = 2,
    desert = 3,
    savanna = 4,
    snow = 5,
    taiga = 6,
    tundra = 7,
    ocean = 8,
    beach = 9,
    town = 10,
    underground = 11,
    deep_underground = 12,
    underground_air = 13,
    alpine = 14,
};

enum class TerrainFluidId : std::uint8_t {
    none = 0,
    water = 1,
};

enum class TerrainProvenanceKind : std::uint8_t {
    generated = 0,
    typed_delta = 1,
};

struct Vec3d {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;

    bool operator==(const Vec3d &other) const noexcept;
};

struct TerrainCell {
    CellCoord coordinate;
    double density = 0.0;
    double surface_y = 0.0;
    bool solid = false;
    TerrainMaterialId material = TerrainMaterialId::air;
    TerrainBiomeId surface_biome = TerrainBiomeId::plains;
    TerrainBiomeId resolved_biome = TerrainBiomeId::plains;
    TerrainFluidId fluid = TerrainFluidId::none;
    TerrainProvenanceKind provenance = TerrainProvenanceKind::generated;
    std::string provenance_id;
    std::uint64_t provenance_revision = 0;

    bool operator==(const TerrainCell &other) const noexcept;
};

struct DeclaredFeatureBlocker {
    std::string stable_id;
    Vec3d center;
    Vec3d size;
    std::string semantic_class;
    std::string physical_intent;

    bool operator==(const DeclaredFeatureBlocker &other) const noexcept;
};

struct TerrainSnapshotDescriptor {
    static constexpr std::uint32_t SCHEMA = 1;

    RequestAuthority authority;
    std::string transaction_id;
    CellRegion sample_region;
    std::uint32_t schema = SCHEMA;
};

// Constructed only through create(), which validates complete row-major input
// and owns all cell/blocker/canonical storage. Public access is const-only.
class TerrainSnapshot final {
public:
    static TerrainSnapshot create(
        TerrainSnapshotDescriptor descriptor,
        std::vector<TerrainCell> cells,
        std::vector<DeclaredFeatureBlocker> blockers = {});

    const TerrainSnapshotDescriptor &descriptor() const noexcept;
    const CellRegion &sample_region() const noexcept;
    const std::vector<TerrainCell> &cells() const noexcept;
    const std::vector<DeclaredFeatureBlocker> &blockers() const noexcept;
    const std::vector<std::uint8_t> &canonical_bytes() const noexcept;
    const Sha256Digest &digest() const noexcept;
    std::string digest_hex() const;

    std::size_t size_x() const noexcept;
    std::size_t size_y() const noexcept;
    std::size_t size_z() const noexcept;
    bool contains(const CellCoord &coordinate) const noexcept;
    std::size_t index_of(const CellCoord &coordinate) const;
    const TerrainCell &at(const CellCoord &coordinate) const;
    const TerrainCell &at_index(std::size_t index) const;

private:
    TerrainSnapshot(
        TerrainSnapshotDescriptor descriptor,
        std::vector<TerrainCell> cells,
        std::vector<DeclaredFeatureBlocker> blockers,
        std::vector<std::uint8_t> canonical_bytes,
        Sha256Digest digest,
        std::size_t size_x,
        std::size_t size_y,
        std::size_t size_z);

    TerrainSnapshotDescriptor descriptor_;
    std::vector<TerrainCell> cells_;
    std::vector<DeclaredFeatureBlocker> blockers_;
    std::vector<std::uint8_t> canonical_bytes_;
    Sha256Digest digest_{};
    std::size_t size_x_ = 0;
    std::size_t size_y_ = 0;
    std::size_t size_z_ = 0;
};

const char *terrain_material_name(TerrainMaterialId material) noexcept;
const char *terrain_biome_name(TerrainBiomeId biome) noexcept;

} // namespace voxel::world_backend
