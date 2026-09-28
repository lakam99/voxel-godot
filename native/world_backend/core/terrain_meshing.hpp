#pragma once

#include "terrain_snapshot.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace voxel::world_backend {

enum class TerrainMeshingStatus : std::uint8_t {
    ready = 0,
    invalid_request = 1,
    unsupported_detail = 2,
    incomplete_halo = 3,
    coordinate_overflow = 4,
    nonfinite_geometry = 5,
    wrong_world = 6,
    stale_owner = 7,
    cancelled = 8,
    stale_source = 9,
};

enum class TerrainSurfaceSource : std::uint8_t {
    terrain = 0,
    declared_feature_blocker = 1,
};

struct TerrainTileMeshRequest {
    CellRegion owned_cube_region;
    // Builder revision 1 preserves the existing chunk frame: X/Z are local to
    // this origin while Y remains in world metres. local_origin.y must be zero.
    CellCoord local_origin;
    double cell_size = 1.35;
    std::uint32_t detail_level = 0;
    std::uint32_t lod_level = 0;
    std::uint32_t step_cells = 1;
    RequestAuthority current_authority;
};

struct TerrainRenderVertex {
    Vec3d position;
    Vec3d normal;
    TerrainMaterialId material = TerrainMaterialId::stone;
    TerrainBiomeId air_biome = TerrainBiomeId::plains;
    TerrainSurfaceSource source = TerrainSurfaceSource::terrain;
    std::string source_id;

    bool operator==(const TerrainRenderVertex &other) const noexcept;
};

struct TerrainRenderInputs {
    std::vector<TerrainRenderVertex> vertices;

    std::size_t triangle_count() const noexcept;
    bool operator==(const TerrainRenderInputs &other) const noexcept;
};

struct TerrainCollisionTriangle {
    std::array<Vec3d, 3> positions;
    TerrainSurfaceSource source = TerrainSurfaceSource::terrain;
    std::string source_id;

    bool operator==(const TerrainCollisionTriangle &other) const noexcept;
};

struct TerrainCollisionInputs {
    std::vector<TerrainCollisionTriangle> triangles;

    std::size_t face_vertex_count() const noexcept;
    bool operator==(const TerrainCollisionInputs &other) const noexcept;
};

struct TerrainMeshingDiagnostics {
    std::size_t visited_cubes = 0;
    std::size_t mixed_cubes = 0;
    std::size_t rejected_degenerate_triangles = 0;
    std::size_t terrain_triangles = 0;
    std::size_t blocker_triangles = 0;

    bool operator==(const TerrainMeshingDiagnostics &other) const noexcept;
};

struct TerrainTileGeometry {
    TerrainMeshingStatus status = TerrainMeshingStatus::invalid_request;
    Sha256Digest snapshot_digest{};
    TerrainRenderInputs render;
    TerrainCollisionInputs collision;
    TerrainMeshingDiagnostics diagnostics;

    bool ready() const noexcept;
};

struct TerrainCollisionBuild {
    TerrainMeshingStatus status = TerrainMeshingStatus::invalid_request;
    Sha256Digest snapshot_digest{};
    TerrainCollisionInputs collision;
    TerrainMeshingDiagnostics diagnostics;

    bool ready() const noexcept;
};

// The owned region is a half-open region of cube origins. Its required source
// domain includes the cube-corner boundary and one further sample on both sides
// for the centered gradients used by render normals.
TerrainMeshingStatus required_terrain_sample_region(
    const TerrainTileMeshRequest &request,
    CellRegion &region_out) noexcept;

bool terrain_tile_reads_cell(
    const TerrainTileMeshRequest &request,
    const CellCoord &cell) noexcept;

TerrainTileGeometry build_terrain_tile_geometry(
    const TerrainSnapshot &snapshot,
    const TerrainTileMeshRequest &request);

// Collision compilation uses the same immutable snapshot and canonical
// surface emitter, but never constructs render vertices or an engine mesh.
TerrainCollisionBuild build_terrain_collision(
    const TerrainSnapshot &snapshot,
    const TerrainTileMeshRequest &request);

} // namespace voxel::world_backend
