#pragma once

#include "native_effective_terrain_source.hpp"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <vector>

namespace voxel::world_backend {

struct NativeEffectiveTerrainBatchLimits {
    std::size_t max_surface_columns = 4096;
    std::size_t max_cell_centers = 4096;
    std::size_t max_lattice_numeric = 4096;
    std::size_t max_world_numeric = 4096;
    std::size_t max_surface_projection_numeric = 4096;
    std::size_t max_total_queries = 16384;
    // Logical retained bytes, independent of allocator capacity and padding.
    // See NativeEffectiveTerrainBatch::execute for the exact accounting model.
    std::size_t max_prepared_payload_bytes = 16U * 1024U * 1024U;
    std::size_t max_surface_projections = 4096;
    std::size_t max_walkable_projections = 4096;
    std::size_t max_known_height_projections = 4096;
    std::size_t max_projection_total_queries = 4096;
    std::size_t max_projection_vertical_candidates_per_query = 512;
    std::size_t max_projection_total_vertical_candidates = 65536;
    std::size_t max_projection_cell_reads_per_query = 1025;
    std::size_t max_projection_total_cell_reads = 131072;
    std::size_t max_projection_payload_bytes = 16U * 1024U * 1024U;
};

enum class NativeEffectiveTerrainBatchRejectReason : std::uint8_t {
    surface_column_limit = 1,
    cell_center_limit = 2,
    lattice_numeric_limit = 3,
    world_numeric_limit = 4,
    surface_projection_numeric_limit = 5,
    total_limit = 6,
    prepared_payload_limit = 7,
    surface_projection_limit = 8,
    walkable_projection_limit = 9,
    known_height_projection_limit = 10,
    projection_total_limit = 11,
    projection_vertical_per_query_limit = 12,
    projection_vertical_total_limit = 13,
    projection_payload_limit = 14,
    projection_cell_reads_per_query_limit = 15,
    projection_cell_reads_total_limit = 16,
};

class NativeEffectiveTerrainBatchRejected final : public std::length_error {
public:
    explicit NativeEffectiveTerrainBatchRejected(NativeEffectiveTerrainBatchRejectReason reason);
    NativeEffectiveTerrainBatchRejectReason reason() const noexcept;

private:
    NativeEffectiveTerrainBatchRejectReason reason_;
};

enum class NativeEffectiveTerrainBatchQueryKind : std::uint8_t {
    arbitrary_world_numeric = 1,
    surface_projection_numeric = 2,
};

struct NativeEffectiveWorldNumericBatchQuery {
    static constexpr std::uint32_t SEMANTIC_REVISION = 1;
    WorldFloat32Position position;
    // TerrainVolumeService.numeric_sample_world applies terrain-mesh metadata
    // policy even though it resolves an effective cell-centre state.
    WorldQueryIntent intent = WorldQueryIntent::terrain_mesh;
    std::uint32_t semantic_revision = SEMANTIC_REVISION;
};

struct NativeEffectiveSurfaceProjectionNumericBatchQuery {
    static constexpr std::uint32_t SEMANTIC_REVISION = 1;
    CellCoord coordinate;
    WorldQueryIntent intent = WorldQueryIntent::terrain_collision;
    std::uint32_t semantic_revision = SEMANTIC_REVISION;
};

NativeEffectiveTerrainBatchQueryKind native_effective_batch_query_kind(
    const NativeEffectiveWorldNumericBatchQuery &) noexcept;
NativeEffectiveTerrainBatchQueryKind native_effective_batch_query_kind(
    const NativeEffectiveSurfaceProjectionNumericBatchQuery &) noexcept;

struct NativeEffectiveTerrainBatchRequest {
    std::vector<WorldSurfaceColumnQuery> surface_columns;
    std::vector<WorldCellCenterQuery> cell_centers;
    std::vector<WorldLatticeQuery> lattice_numeric;
    std::vector<NativeEffectiveWorldNumericBatchQuery> world_numeric;
    std::vector<NativeEffectiveSurfaceProjectionNumericBatchQuery> surface_projection_numeric;
};

struct NativeEffectiveSurfaceColumnBatchRecord {
    WorldSurfaceColumnQuery requested;
    std::int32_t source_x = 0;
    std::int32_t source_z = 0;
    double reference_surface_y = 0.0;
    double deformed_surface_y = 0.0;
    double volume_surface_y = 0.0;
    TerrainBiomeId biome = TerrainBiomeId::plains;
};

// Cell-center records are deliberately flattened. Consumers can transpose
// them directly into SoA publication buffers without interpreting metadata or
// reconstructing section/local coordinates.
struct NativeEffectiveCellCenterBatchRecord {
    WorldCellCenterQuery requested;
    CellCoord source_cell;
    TerrainMaterialId material = TerrainMaterialId::air;
    TerrainBiomeId biome = TerrainBiomeId::plains;
    TerrainFluidId fluid = TerrainFluidId::none;
    bool solid = false;
    double density = 0.0;
    NativeCellLight light;
    bool generated = true;
    bool edited = false;
    std::optional<NativeCellState> edited_sparse_state;
};

struct NativeEffectiveLatticeBatchRecord {
    WorldLatticeQuery requested;
    NativeEffectiveNumericFacts facts;
    std::optional<NativeCellState> edited_sparse_state;
};

struct NativeEffectiveWorldBatchRecord {
    NativeEffectiveWorldNumericBatchQuery requested;
    NativeEffectiveNumericFacts facts;
    std::optional<NativeCellState> edited_sparse_state;
};

struct NativeEffectiveSurfaceProjectionBatchRecord {
    NativeEffectiveSurfaceProjectionNumericBatchQuery requested;
    NativeEffectiveNumericFacts facts;
    std::optional<NativeCellState> edited_sparse_state;
};

struct NativeEffectiveTerrainBatchResult {
    static constexpr std::uint32_t SCHEMA_REVISION = 2;
    std::uint32_t schema_revision = SCHEMA_REVISION;
    NativeTerrainPageKey primary_page;
    WorldPhysicalContentIdentity definition_physical_identity;
    WorldPhysicalContentIdentity pin_physical_identity;
    std::uint64_t terrain_delta_revision = 0;
    std::uint64_t shaping_registry_revision = 0;
    WorldPhysicalContentIdentity shaping_registry_content_identity;
    std::size_t prepared_payload_bytes = 0;
    std::vector<NativeEffectiveSurfaceColumnBatchRecord> surface_columns;
    std::vector<NativeEffectiveCellCenterBatchRecord> cell_centers;
    std::vector<NativeEffectiveLatticeBatchRecord> lattice_numeric;
    std::vector<NativeEffectiveWorldBatchRecord> world_numeric;
    std::vector<NativeEffectiveSurfaceProjectionBatchRecord> surface_projection_numeric;
};

struct NativeEffectiveTerrainProjectionBatchRequest {
    std::vector<NativeEffectiveSurfaceProjectionQuery> surface_projections;
    std::vector<NativeEffectiveSurfaceProjectionQuery> walkable_projections;
    std::vector<NativeEffectiveKnownHeightProjectionQuery> known_height_projections;
};

struct NativeEffectiveFullSurfaceProjectionBatchRecord {
    NativeEffectiveSurfaceProjectionQuery requested;
    NativeEffectiveSurfaceProjectionFacts facts;
};

struct NativeEffectiveWalkableProjectionBatchRecord {
    NativeEffectiveSurfaceProjectionQuery requested;
    NativeEffectiveWalkableProjectionFacts facts;
};

struct NativeEffectiveKnownHeightProjectionBatchRecord {
    NativeEffectiveKnownHeightProjectionQuery requested;
    NativeEffectiveKnownHeightProjectionFacts facts;
};

struct NativeEffectiveTerrainProjectionBatchResult {
    static constexpr std::uint32_t SCHEMA_REVISION = 1;
    std::uint32_t schema_revision = SCHEMA_REVISION;
    NativeTerrainPageKey primary_page;
    WorldPhysicalContentIdentity definition_physical_identity;
    WorldPhysicalContentIdentity pin_physical_identity;
    std::uint64_t terrain_delta_revision = 0;
    std::uint64_t shaping_registry_revision = 0;
    WorldPhysicalContentIdentity shaping_registry_content_identity;
    std::size_t admitted_vertical_candidates = 0;
    std::size_t admitted_cell_reads = 0;
    std::size_t prepared_payload_bytes = 0;
    std::vector<NativeEffectiveFullSurfaceProjectionBatchRecord> surface_projections;
    std::vector<NativeEffectiveWalkableProjectionBatchRecord> walkable_projections;
    std::vector<NativeEffectiveKnownHeightProjectionBatchRecord> known_height_projections;
};

// Immutable, pin-owning batch facade. execute() has the strong exception
// guarantee: limits and every query are resolved into a local result, so an
// invalid member can never expose a partially filled result to the caller.
class NativeEffectiveTerrainBatch final {
public:
    explicit NativeEffectiveTerrainBatch(
        WorldSourcePin pin, NativeEffectiveTerrainBatchLimits limits = {});
    NativeEffectiveTerrainBatch(const NativeEffectiveTerrainBatch &) = delete;
    NativeEffectiveTerrainBatch(NativeEffectiveTerrainBatch &&) noexcept = default;
    NativeEffectiveTerrainBatch &operator=(const NativeEffectiveTerrainBatch &) = delete;
    NativeEffectiveTerrainBatch &operator=(NativeEffectiveTerrainBatch &&) = delete;

    const WorldSourcePin &pin() const noexcept;
    const NativeEffectiveTerrainBatchLimits &limits() const noexcept;
    NativeEffectiveTerrainBatchResult execute(const NativeEffectiveTerrainBatchRequest &request) const;
    NativeEffectiveTerrainProjectionBatchResult execute_projections(
        const NativeEffectiveTerrainProjectionBatchRequest &request) const;
    double sample_continuous_volume_surface_y(const WorldSurfaceColumnQuery &query) const;

private:
    NativeEffectiveTerrainSource source_;
    NativeEffectiveTerrainBatchLimits limits_;
};

} // namespace voxel::world_backend
