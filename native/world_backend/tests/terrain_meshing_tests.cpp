#include "test_harness.hpp"

#include "terrain_meshing.hpp"
#include "terrain_snapshot.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

RequestAuthority authority(const std::uint64_t source_revision = 1) {
    RequestAuthority value{};
    value.world_digest[0] = 41;
    value.owner.value = 1;
    value.cancellation.value = 1;
    value.source_revision.value = source_revision;
    return value;
}

TerrainSnapshotDescriptor descriptor(
    const CellRegion &region,
    const RequestAuthority &request_authority = authority()) {
    TerrainSnapshotDescriptor value;
    value.authority = request_authority;
    value.transaction_id = "n2-meshing-fixture";
    value.sample_region = region;
    return value;
}

std::vector<TerrainCell> cells_for(
    const CellRegion &region,
    const RequestAuthority &request_authority,
    const std::function<double(const CellCoord &)> &density,
    const std::function<double(const CellCoord &)> &surface_y = [](const CellCoord &) { return 4.0; }) {
    std::vector<TerrainCell> cells;
    for (std::int64_t y = region.minimum.y; y < region.maximum_exclusive.y; ++y) {
        for (std::int64_t z = region.minimum.z; z < region.maximum_exclusive.z; ++z) {
            for (std::int64_t x = region.minimum.x; x < region.maximum_exclusive.x; ++x) {
                const CellCoord coordinate{
                    static_cast<std::int32_t>(x),
                    static_cast<std::int32_t>(y),
                    static_cast<std::int32_t>(z),
                };
                const double value = density(coordinate);
                const bool solid = value >= 0.0;
                cells.push_back({
                    coordinate,
                    value,
                    surface_y(coordinate),
                    solid,
                    solid ? TerrainMaterialId::stone : TerrainMaterialId::air,
                    TerrainBiomeId::plains,
                    solid ? TerrainBiomeId::underground : TerrainBiomeId::underground_air,
                    TerrainFluidId::none,
                    TerrainProvenanceKind::generated,
                    "generator:atlas-1492",
                    request_authority.source_revision.value,
                });
            }
        }
    }
    return cells;
}

TerrainSnapshot snapshot_for(
    const CellRegion &region,
    const std::function<double(const CellCoord &)> &density,
    std::vector<DeclaredFeatureBlocker> blockers = {},
    const RequestAuthority &request_authority = authority()) {
    return TerrainSnapshot::create(
        descriptor(region, request_authority),
        cells_for(region, request_authority, density),
        std::move(blockers));
}

TerrainTileMeshRequest request_for(
    const CellRegion &owned,
    const RequestAuthority &current = authority(),
    const CellCoord local_origin = {}) {
    TerrainTileMeshRequest request;
    request.owned_cube_region = owned;
    request.local_origin = local_origin;
    request.current_authority = current;
    return request;
}

CellRegion unit_sample_region() {
    return {{-1, -1, -1}, {3, 3, 3}};
}

CellRegion unit_cube_region() {
    return {{0, 0, 0}, {1, 1, 1}};
}

double cube_corner_density(
    const CellCoord &cell,
    const std::vector<CellCoord> &solid_corners,
    const double solid_density = 1.0,
    const double air_density = -1.0) {
    return std::find(solid_corners.begin(), solid_corners.end(), cell) != solid_corners.end()
        ? solid_density
        : air_density;
}

Vec3d triangle_normal(const TerrainCollisionTriangle &triangle) {
    const Vec3d ab{
        triangle.positions[1].x - triangle.positions[0].x,
        triangle.positions[1].y - triangle.positions[0].y,
        triangle.positions[1].z - triangle.positions[0].z,
    };
    const Vec3d ac{
        triangle.positions[2].x - triangle.positions[0].x,
        triangle.positions[2].y - triangle.positions[0].y,
        triangle.positions[2].z - triangle.positions[0].z,
    };
    return {
        ab.y * ac.z - ab.z * ac.y,
        ab.z * ac.x - ab.x * ac.z,
        ab.x * ac.y - ab.y * ac.x,
    };
}

void expect_ready_equal_collision(const TerrainSnapshot &snapshot, const TerrainTileMeshRequest &request) {
    const TerrainTileGeometry combined = build_terrain_tile_geometry(snapshot, request);
    const TerrainCollisionBuild collision_only = build_terrain_collision(snapshot, request);
    VWB_EXPECT(combined.ready());
    VWB_EXPECT(collision_only.ready());
    VWB_EXPECT_EQ(combined.snapshot_digest, collision_only.snapshot_digest);
    VWB_EXPECT_EQ(combined.collision, collision_only.collision);
    VWB_EXPECT_EQ(combined.diagnostics, collision_only.diagnostics);
}

} // namespace

VWB_TEST(terrain_meshing_empty_and_full_tiles_are_valid_sealed_artifacts) {
    for (const double density : {-1.0, 1.0}) {
        const TerrainSnapshot snapshot = snapshot_for(
            unit_sample_region(), [density](const CellCoord &) { return density; });
        const TerrainTileGeometry geometry = build_terrain_tile_geometry(
            snapshot, request_for(unit_cube_region()));
        VWB_EXPECT(geometry.ready());
        VWB_EXPECT(geometry.render.vertices.empty());
        VWB_EXPECT(geometry.collision.triangles.empty());
        VWB_EXPECT_EQ(static_cast<std::size_t>(1), geometry.diagnostics.visited_cubes);
        VWB_EXPECT_EQ(static_cast<std::size_t>(0), geometry.diagnostics.mixed_cubes);
        expect_ready_equal_collision(snapshot, request_for(unit_cube_region()));
    }
}

VWB_TEST(terrain_meshing_preserves_one_two_and_three_solid_tetrahedron_cases) {
    const CellCoord corner0{0, 0, 0};
    const CellCoord corner6{1, 1, 1};
    struct Fixture {
        std::vector<CellCoord> solid;
        std::size_t expected_triangles;
    };
    const std::vector<Fixture> fixtures = {
        {{corner0}, 6},
        {{corner0, corner6}, 12},
    };
    for (const Fixture &fixture : fixtures) {
        const TerrainSnapshot snapshot = snapshot_for(
            unit_sample_region(),
            [&fixture](const CellCoord &cell) {
                return cube_corner_density(cell, fixture.solid);
            });
        const TerrainTileGeometry geometry = build_terrain_tile_geometry(
            snapshot, request_for(unit_cube_region()));
        VWB_EXPECT(geometry.ready());
        VWB_EXPECT_EQ(fixture.expected_triangles, geometry.collision.triangles.size());
        VWB_EXPECT_EQ(fixture.expected_triangles, geometry.render.triangle_count());
        expect_ready_equal_collision(snapshot, request_for(unit_cube_region()));
    }

    const TerrainSnapshot three_solid = snapshot_for(
        unit_sample_region(),
        [corner0](const CellCoord &cell) {
            const bool cube_corner = cell.x >= 0 && cell.x <= 1 &&
                cell.y >= 0 && cell.y <= 1 && cell.z >= 0 && cell.z <= 1;
            return cube_corner && !(cell == corner0) ? 1.0 : -1.0;
        });
    const TerrainTileGeometry geometry = build_terrain_tile_geometry(
        three_solid, request_for(unit_cube_region()));
    VWB_EXPECT(geometry.ready());
    VWB_EXPECT_EQ(static_cast<std::size_t>(6), geometry.collision.triangles.size());
    expect_ready_equal_collision(three_solid, request_for(unit_cube_region()));

    std::vector<TerrainCell> ordered_material_cells = cells_for(
        unit_sample_region(), authority(),
        [corner0, corner6](const CellCoord &cell) {
            return cell == corner0 || cell == corner6 ? 1.0 : -1.0;
        });
    for (TerrainCell &cell : ordered_material_cells) {
        if (cell.coordinate == corner0) cell.material = TerrainMaterialId::copper_ore;
        if (cell.coordinate == corner6) cell.material = TerrainMaterialId::iron_ore;
    }
    const TerrainSnapshot ordered_materials = TerrainSnapshot::create(
        descriptor(unit_sample_region()), std::move(ordered_material_cells), {});
    const TerrainTileGeometry selected = build_terrain_tile_geometry(
        ordered_materials, request_for(unit_cube_region()));
    VWB_EXPECT(selected.ready());
    for (const TerrainRenderVertex &vertex : selected.render.vertices) {
        VWB_EXPECT_EQ(TerrainMaterialId::copper_ore, vertex.material);
    }
}

VWB_TEST(terrain_meshing_skips_both_all_air_and_all_solid_tetrahedra_in_a_mixed_cube) {
    const std::vector<CellCoord> first_tetrahedron = {
        {0, 0, 0},
        {1, 1, 0},
        {1, 0, 0},
        {1, 1, 1},
    };
    const TerrainSnapshot with_all_solid_tetrahedron = snapshot_for(
        unit_sample_region(),
        [&first_tetrahedron](const CellCoord &cell) {
            return cube_corner_density(cell, first_tetrahedron);
        });
    const TerrainTileGeometry solid_tetrahedron = build_terrain_tile_geometry(
        with_all_solid_tetrahedron, request_for(unit_cube_region()));
    VWB_EXPECT(solid_tetrahedron.ready());
    VWB_EXPECT_EQ(static_cast<std::size_t>(1), solid_tetrahedron.diagnostics.mixed_cubes);
    VWB_EXPECT(!solid_tetrahedron.collision.triangles.empty());

    const TerrainSnapshot with_all_air_tetrahedron = snapshot_for(
        unit_sample_region(),
        [&first_tetrahedron](const CellCoord &cell) {
            const bool cube_corner = cell.x >= 0 && cell.x <= 1 &&
                cell.y >= 0 && cell.y <= 1 && cell.z >= 0 && cell.z <= 1;
            return cube_corner &&
                    std::find(first_tetrahedron.begin(), first_tetrahedron.end(), cell) ==
                        first_tetrahedron.end()
                ? 1.0
                : -1.0;
        });
    const TerrainTileGeometry air_tetrahedron = build_terrain_tile_geometry(
        with_all_air_tetrahedron, request_for(unit_cube_region()));
    VWB_EXPECT(air_tetrahedron.ready());
    VWB_EXPECT_EQ(static_cast<std::size_t>(1), air_tetrahedron.diagnostics.mixed_cubes);
    VWB_EXPECT(!air_tetrahedron.collision.triangles.empty());
}

VWB_TEST(terrain_meshing_zero_is_solid_and_near_zero_uses_midpoint_fallback) {
    const CellCoord corner0{0, 0, 0};
    const TerrainSnapshot near_zero = snapshot_for(
        unit_sample_region(),
        [corner0](const CellCoord &cell) {
            return cell == corner0 ? 0.0 : -0.000001;
        });
    const TerrainTileGeometry midpoint = build_terrain_tile_geometry(
        near_zero, request_for(unit_cube_region()));
    VWB_EXPECT(midpoint.ready());
    VWB_EXPECT_EQ(static_cast<std::size_t>(6), midpoint.collision.triangles.size());
    const Vec3d first = midpoint.collision.triangles.front().positions.front();
    VWB_EXPECT_EQ(Vec3d({0.5 * 1.35, 0.5 * 1.35, 0.0}), first);

    const TerrainSnapshot exact_zero = snapshot_for(
        unit_sample_region(),
        [corner0](const CellCoord &cell) { return cell == corner0 ? 0.0 : -1.0; });
    const TerrainTileGeometry degenerate = build_terrain_tile_geometry(
        exact_zero, request_for(unit_cube_region()));
    VWB_EXPECT(degenerate.ready());
    VWB_EXPECT_EQ(static_cast<std::size_t>(1), degenerate.diagnostics.mixed_cubes);
    VWB_EXPECT_EQ(static_cast<std::size_t>(6), degenerate.diagnostics.rejected_degenerate_triangles);
    VWB_EXPECT(degenerate.collision.triangles.empty());
}

VWB_TEST(terrain_meshing_orients_faces_from_solid_toward_air_and_preserves_material) {
    const CellRegion region = unit_sample_region();
    std::vector<TerrainCell> cells = cells_for(
        region, authority(), [](const CellCoord &cell) { return cell.y <= 0 ? 1.0 : -1.0; });
    for (TerrainCell &cell : cells) {
        if (cell.solid) {
            cell.material = TerrainMaterialId::copper_ore;
        }
    }
    const TerrainSnapshot snapshot = TerrainSnapshot::create(
        descriptor(region), std::move(cells), {});
    const TerrainTileGeometry geometry = build_terrain_tile_geometry(
        snapshot, request_for(unit_cube_region()));
    VWB_EXPECT(geometry.ready());
    VWB_EXPECT(!geometry.collision.triangles.empty());
    for (const TerrainCollisionTriangle &triangle : geometry.collision.triangles) {
        VWB_EXPECT(triangle_normal(triangle).y > 0.0);
    }
    for (const TerrainRenderVertex &vertex : geometry.render.vertices) {
        VWB_EXPECT_EQ(TerrainMaterialId::copper_ore, vertex.material);
        VWB_EXPECT_EQ(TerrainBiomeId::underground_air, vertex.air_biome);
        VWB_EXPECT_EQ(Vec3d({0.0, 1.0, 0.0}), vertex.normal);
    }
}

VWB_TEST(terrain_meshing_uses_surface_gradient_shallow_and_density_gradient_deep) {
    const CellRegion region = unit_sample_region();
    const auto density = [](const CellCoord &cell) { return cell.x <= 0 ? 1.0 : -1.0; };
    const TerrainSnapshot shallow = TerrainSnapshot::create(
        descriptor(region),
        cells_for(region, authority(), density, [](const CellCoord &) { return 1.0; }),
        {});
    const TerrainSnapshot deep = TerrainSnapshot::create(
        descriptor(region),
        cells_for(region, authority(), density, [](const CellCoord &) { return 10.0; }),
        {});
    const TerrainTileGeometry shallow_geometry = build_terrain_tile_geometry(
        shallow, request_for(unit_cube_region()));
    const TerrainTileGeometry deep_geometry = build_terrain_tile_geometry(
        deep, request_for(unit_cube_region()));
    VWB_EXPECT(shallow_geometry.ready() && deep_geometry.ready());
    VWB_EXPECT(!shallow_geometry.render.vertices.empty());
    VWB_EXPECT_EQ(shallow_geometry.render.vertices.size(), deep_geometry.render.vertices.size());
    for (const TerrainRenderVertex &vertex : shallow_geometry.render.vertices) {
        VWB_EXPECT_EQ(Vec3d({0.0, 1.0, 0.0}), vertex.normal);
    }
    for (const TerrainRenderVertex &vertex : deep_geometry.render.vertices) {
        VWB_EXPECT_EQ(Vec3d({1.0, 0.0, 0.0}), vertex.normal);
    }
}

VWB_TEST(terrain_meshing_negative_tiles_share_a_seam_without_duplicate_ownership) {
    const CellRegion sample_region{{-2, -1, -1}, {3, 3, 3}};
    const TerrainSnapshot snapshot = snapshot_for(
        sample_region, [](const CellCoord &cell) { return cell.y <= 0 ? 1.0 : -1.0; });
    const TerrainTileMeshRequest left_request = request_for({{-1, 0, 0}, {0, 1, 1}});
    const TerrainTileMeshRequest right_request = request_for({{0, 0, 0}, {1, 1, 1}});
    const TerrainTileMeshRequest combined_request = request_for({{-1, 0, 0}, {1, 1, 1}});
    const TerrainCollisionBuild left = build_terrain_collision(snapshot, left_request);
    const TerrainCollisionBuild right = build_terrain_collision(snapshot, right_request);
    const TerrainCollisionBuild combined = build_terrain_collision(snapshot, combined_request);
    VWB_EXPECT(left.ready() && right.ready() && combined.ready());
    std::vector<TerrainCollisionTriangle> concatenated = left.collision.triangles;
    concatenated.insert(concatenated.end(), right.collision.triangles.begin(), right.collision.triangles.end());
    VWB_EXPECT_EQ(combined.collision.triangles, concatenated);
    for (const TerrainCollisionTriangle &left_triangle : left.collision.triangles) {
        VWB_EXPECT(std::find(right.collision.triangles.begin(), right.collision.triangles.end(), left_triangle) ==
            right.collision.triangles.end());
    }
    VWB_EXPECT(terrain_tile_reads_cell(left_request, {0, 0, 0}));
    VWB_EXPECT(terrain_tile_reads_cell(right_request, {0, 0, 0}));
}

VWB_TEST(terrain_meshing_rejects_incomplete_halo_unsupported_detail_and_overflow) {
    const CellRegion too_small{{0, 0, 0}, {2, 2, 2}};
    const TerrainSnapshot snapshot = snapshot_for(
        too_small, [](const CellCoord &) { return -1.0; });
    TerrainTileMeshRequest request = request_for(unit_cube_region());
    VWB_EXPECT_EQ(TerrainMeshingStatus::incomplete_halo,
        build_terrain_tile_geometry(snapshot, request).status);
    request.step_cells = 2;
    VWB_EXPECT_EQ(TerrainMeshingStatus::unsupported_detail,
        build_terrain_tile_geometry(snapshot, request).status);
    request.step_cells = 1;
    request.lod_level = 1;
    VWB_EXPECT_EQ(TerrainMeshingStatus::unsupported_detail,
        build_terrain_tile_geometry(snapshot, request).status);
    request.lod_level = 0;
    request.detail_level = 1;
    VWB_EXPECT_EQ(TerrainMeshingStatus::unsupported_detail,
        build_terrain_tile_geometry(snapshot, request).status);
    request.detail_level = 0;
    request.cell_size = 0.0;
    VWB_EXPECT_EQ(TerrainMeshingStatus::invalid_request,
        build_terrain_tile_geometry(snapshot, request).status);
    request.cell_size = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_EQ(TerrainMeshingStatus::invalid_request,
        build_terrain_tile_geometry(snapshot, request).status);
    request.cell_size = 1.35;
    request.local_origin.y = 1;
    VWB_EXPECT_EQ(TerrainMeshingStatus::invalid_request,
        build_terrain_tile_geometry(snapshot, request).status);
    request.local_origin.y = 0;
    request.owned_cube_region = {{0, 0, 0}, {0, 1, 1}};
    VWB_EXPECT_EQ(TerrainMeshingStatus::invalid_request,
        build_terrain_tile_geometry(snapshot, request).status);
    request.owned_cube_region = {
        {std::numeric_limits<std::int32_t>::min(), 0, 0},
        {std::numeric_limits<std::int32_t>::min() + 1, 1, 1},
    };
    VWB_EXPECT_EQ(TerrainMeshingStatus::coordinate_overflow,
        build_terrain_tile_geometry(snapshot, request).status);
    request.owned_cube_region = {{-1000000000, -1000000000, -1000000000},
        {1000000000, 1000000000, 1000000000}};
    VWB_EXPECT_EQ(TerrainMeshingStatus::coordinate_overflow,
        build_terrain_tile_geometry(snapshot, request).status);
    request.step_cells = 2;
    VWB_EXPECT(!terrain_tile_reads_cell(request, {0, 0, 0}));
}

VWB_TEST(terrain_meshing_snapshot_rejects_nonfinite_source_and_accepts_explicit_air) {
    std::vector<TerrainCell> malformed = cells_for(
        unit_sample_region(), authority(), [](const CellCoord &) { return -1.0; });
    malformed.front().density = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(std::invalid_argument,
        TerrainSnapshot::create(descriptor(unit_sample_region()), std::move(malformed), {}));

    std::vector<TerrainCell> explicit_air = cells_for(
        unit_sample_region(), authority(), [](const CellCoord &) { return -1.0; });
    for (TerrainCell &cell : explicit_air) {
        if (cell.coordinate == CellCoord{0, 0, 0}) {
            cell.provenance = TerrainProvenanceKind::typed_delta;
            cell.provenance_id = "delta:explicit-air";
            cell.provenance_revision = 7;
        }
    }
    const TerrainSnapshot snapshot = TerrainSnapshot::create(
        descriptor(unit_sample_region()), std::move(explicit_air), {});
    const TerrainCell &air = snapshot.at({0, 0, 0});
    VWB_EXPECT(!air.solid);
    VWB_EXPECT(air.density < 0.0);
    VWB_EXPECT_EQ(TerrainProvenanceKind::typed_delta, air.provenance);
    VWB_EXPECT_EQ(std::string("delta:explicit-air"), air.provenance_id);
}

VWB_TEST(terrain_meshing_declared_blocker_has_twelve_canonical_faces_and_one_owner) {
    const CellRegion sample_region{{-1, -1, -1}, {4, 3, 3}};
    const DeclaredFeatureBlocker blocker{
        "feature:test-blocker",
        {0.5, 0.5, 0.5},
        {0.5, 0.5, 0.5},
        "fixture_blocker",
        "blocks_motion",
    };
    const TerrainSnapshot snapshot = snapshot_for(
        sample_region, [](const CellCoord &) { return -1.0; }, {blocker});
    const TerrainTileGeometry owner = build_terrain_tile_geometry(
        snapshot, request_for(unit_cube_region()));
    VWB_EXPECT(owner.ready());
    VWB_EXPECT_EQ(static_cast<std::size_t>(12), owner.collision.triangles.size());
    VWB_EXPECT_EQ(static_cast<std::size_t>(12), owner.render.triangle_count());
    VWB_EXPECT_EQ(static_cast<std::size_t>(12), owner.diagnostics.blocker_triangles);
    VWB_EXPECT_EQ(TerrainSurfaceSource::declared_feature_blocker,
        owner.collision.triangles.front().source);
    VWB_EXPECT_EQ(std::string("feature:test-blocker"),
        owner.collision.triangles.front().source_id);
    VWB_EXPECT_EQ(Vec3d({0.25, 0.25, 0.25}),
        owner.collision.triangles.front().positions[0]);
    VWB_EXPECT_EQ(Vec3d({0.75, 0.75, 0.25}),
        owner.collision.triangles.front().positions[1]);
    VWB_EXPECT_EQ(Vec3d({0.75, 0.25, 0.25}),
        owner.collision.triangles.front().positions[2]);
    const TerrainTileGeometry neighbor = build_terrain_tile_geometry(
        snapshot, request_for({{1, 0, 0}, {2, 1, 1}}));
    VWB_EXPECT(neighbor.ready());
    VWB_EXPECT(neighbor.collision.triangles.empty());
    expect_ready_equal_collision(snapshot, request_for(unit_cube_region()));
}

VWB_TEST(terrain_meshing_terrain_and_blocker_shapes_partition_losslessly) {
    const DeclaredFeatureBlocker blocker{
        "feature:partitioned-blocker",
        {0.5, 0.5, 0.5},
        {0.25, 0.25, 0.25},
        "fixture_blocker",
        "blocks_motion",
    };
    const TerrainSnapshot snapshot = snapshot_for(
        unit_sample_region(),
        [](const CellCoord &cell) { return cell.y <= 0 ? 1.0 : -1.0; },
        {blocker});
    const TerrainCollisionBuild build = build_terrain_collision(
        snapshot, request_for(unit_cube_region()));
    VWB_EXPECT(build.ready());
    std::vector<TerrainCollisionTriangle> terrain;
    std::vector<TerrainCollisionTriangle> blockers;
    for (const TerrainCollisionTriangle &triangle : build.collision.triangles) {
        if (triangle.source == TerrainSurfaceSource::terrain) {
            terrain.push_back(triangle);
        } else if (triangle.source == TerrainSurfaceSource::declared_feature_blocker &&
                   triangle.source_id == blocker.stable_id) {
            blockers.push_back(triangle);
        }
    }
    VWB_EXPECT(!terrain.empty());
    VWB_EXPECT_EQ(static_cast<std::size_t>(12), blockers.size());
    VWB_EXPECT_EQ(build.diagnostics.terrain_triangles, terrain.size());
    VWB_EXPECT_EQ(build.diagnostics.blocker_triangles, blockers.size());
    std::vector<TerrainCollisionTriangle> reconstructed = terrain;
    reconstructed.insert(reconstructed.end(), blockers.begin(), blockers.end());
    VWB_EXPECT_EQ(build.collision.triangles, reconstructed);
}

VWB_TEST(terrain_meshing_rejects_nonfinite_output_from_extreme_blocker_arithmetic) {
    const double maximum = std::numeric_limits<double>::max();
    const CellRegion sample_region = unit_sample_region();
    const DeclaredFeatureBlocker blocker{
        "feature:overflow",
        {maximum * 0.75, 0.5, 0.5},
        {maximum, 0.5, 0.5},
        "fixture_blocker",
        "blocks_motion",
    };
    const TerrainSnapshot snapshot = snapshot_for(
        sample_region, [](const CellCoord &) { return -1.0; }, {blocker});
    TerrainTileMeshRequest request = request_for(unit_cube_region());
    request.cell_size = maximum;
    const TerrainTileGeometry rejected = build_terrain_tile_geometry(snapshot, request);
    VWB_EXPECT_EQ(TerrainMeshingStatus::nonfinite_geometry, rejected.status);
    VWB_EXPECT(rejected.render.vertices.empty());
    VWB_EXPECT(rejected.collision.triangles.empty());
}

VWB_TEST(terrain_meshing_is_deterministic_and_collision_only_matches_combined_build) {
    const TerrainSnapshot snapshot = snapshot_for(
        unit_sample_region(), [](const CellCoord &cell) { return cell.y <= 0 ? 1.0 : -1.0; });
    const TerrainTileMeshRequest request = request_for(unit_cube_region());
    const TerrainTileGeometry first = build_terrain_tile_geometry(snapshot, request);
    const TerrainTileGeometry second = build_terrain_tile_geometry(snapshot, request);
    VWB_EXPECT(first.ready() && second.ready());
    VWB_EXPECT_EQ(first.render, second.render);
    VWB_EXPECT_EQ(first.collision, second.collision);
    VWB_EXPECT_EQ(first.diagnostics, second.diagnostics);
    VWB_EXPECT_EQ(first.render.triangle_count() * 3U, first.render.vertices.size());
    VWB_EXPECT_EQ(first.collision.triangles.size() * 3U, first.collision.face_vertex_count());
    expect_ready_equal_collision(snapshot, request);
}

VWB_TEST(terrain_meshing_seam_edit_changes_both_dependent_tile_artifacts) {
    const CellRegion sample_region{{-2, -1, -1}, {3, 3, 3}};
    const auto base_density = [](const CellCoord &cell) { return cell.y <= 0 ? 1.0 : -1.0; };
    const TerrainSnapshot base = snapshot_for(sample_region, base_density);
    std::vector<TerrainCell> edited_cells = cells_for(sample_region, authority(), base_density);
    for (TerrainCell &cell : edited_cells) {
        if (cell.coordinate == CellCoord{0, 0, 0}) {
            cell.density = -1.0;
            cell.solid = false;
            cell.material = TerrainMaterialId::air;
            cell.resolved_biome = TerrainBiomeId::underground_air;
            cell.provenance = TerrainProvenanceKind::typed_delta;
            cell.provenance_id = "delta:cross-seam-air";
            cell.provenance_revision = 2;
        }
    }
    const TerrainSnapshot edited = TerrainSnapshot::create(
        descriptor(sample_region), std::move(edited_cells), {});
    const TerrainTileMeshRequest left_request = request_for({{-1, 0, 0}, {0, 1, 1}});
    const TerrainTileMeshRequest right_request = request_for({{0, 0, 0}, {1, 1, 1}});
    VWB_EXPECT(terrain_tile_reads_cell(left_request, {0, 0, 0}));
    VWB_EXPECT(terrain_tile_reads_cell(right_request, {0, 0, 0}));
    VWB_EXPECT(!(base.digest() == edited.digest()));
    VWB_EXPECT(!(build_terrain_collision(base, left_request).collision ==
        build_terrain_collision(edited, left_request).collision));
    VWB_EXPECT(!(build_terrain_collision(base, right_request).collision ==
        build_terrain_collision(edited, right_request).collision));
}

VWB_TEST(terrain_meshing_rejects_wrong_world_stale_owner_cancellation_and_stale_source) {
    const TerrainSnapshot snapshot = snapshot_for(
        unit_sample_region(), [](const CellCoord &) { return -1.0; });
    TerrainTileMeshRequest request = request_for(unit_cube_region());
    request.current_authority.world_digest[0] = 99;
    VWB_EXPECT_EQ(TerrainMeshingStatus::wrong_world,
        build_terrain_collision(snapshot, request).status);
    request = request_for(unit_cube_region());
    request.current_authority.owner.value = 2;
    VWB_EXPECT_EQ(TerrainMeshingStatus::stale_owner,
        build_terrain_collision(snapshot, request).status);
    request = request_for(unit_cube_region());
    request.current_authority.cancellation.value = 2;
    VWB_EXPECT_EQ(TerrainMeshingStatus::cancelled,
        build_terrain_collision(snapshot, request).status);
    request = request_for(unit_cube_region());
    request.current_authority.source_revision.value = 2;
    VWB_EXPECT_EQ(TerrainMeshingStatus::stale_source,
        build_terrain_collision(snapshot, request).status);
}

VWB_TEST(terrain_meshing_value_contracts_distinguish_every_published_field) {
    const TerrainRenderVertex vertex{
        {1.0, 2.0, 3.0},
        {0.0, 1.0, 0.0},
        TerrainMaterialId::stone,
        TerrainBiomeId::plains,
        TerrainSurfaceSource::terrain,
        "terrain:source",
    };
    VWB_EXPECT(vertex == vertex);
    TerrainRenderVertex changed_vertex = vertex;
    changed_vertex.position.x = 4.0;
    VWB_EXPECT(!(vertex == changed_vertex));
    changed_vertex = vertex;
    changed_vertex.normal.y = -1.0;
    VWB_EXPECT(!(vertex == changed_vertex));
    changed_vertex = vertex;
    changed_vertex.material = TerrainMaterialId::dirt;
    VWB_EXPECT(!(vertex == changed_vertex));
    changed_vertex = vertex;
    changed_vertex.air_biome = TerrainBiomeId::forest;
    VWB_EXPECT(!(vertex == changed_vertex));
    changed_vertex = vertex;
    changed_vertex.source = TerrainSurfaceSource::declared_feature_blocker;
    VWB_EXPECT(!(vertex == changed_vertex));
    changed_vertex = vertex;
    changed_vertex.source_id = "terrain:other";
    VWB_EXPECT(!(vertex == changed_vertex));

    const TerrainRenderInputs render{{vertex}};
    VWB_EXPECT(render == render);
    VWB_EXPECT(!(render == TerrainRenderInputs{}));

    const TerrainCollisionTriangle triangle{
        {{{0.0, 0.0, 0.0}, {1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}}},
        TerrainSurfaceSource::terrain,
        "terrain:source",
    };
    VWB_EXPECT(triangle == triangle);
    TerrainCollisionTriangle changed_triangle = triangle;
    changed_triangle.positions[0].x = 2.0;
    VWB_EXPECT(!(triangle == changed_triangle));
    changed_triangle = triangle;
    changed_triangle.source = TerrainSurfaceSource::declared_feature_blocker;
    VWB_EXPECT(!(triangle == changed_triangle));
    changed_triangle = triangle;
    changed_triangle.source_id = "terrain:other";
    VWB_EXPECT(!(triangle == changed_triangle));

    const TerrainCollisionInputs collision{{triangle}};
    VWB_EXPECT(collision == collision);
    VWB_EXPECT(!(collision == TerrainCollisionInputs{}));

    const TerrainMeshingDiagnostics diagnostics{1, 2, 3, 4, 5};
    VWB_EXPECT(diagnostics == diagnostics);
    for (std::size_t field = 0; field < 5; ++field) {
        TerrainMeshingDiagnostics changed = diagnostics;
        std::size_t *values[] = {
            &changed.visited_cubes,
            &changed.mixed_cubes,
            &changed.rejected_degenerate_triangles,
            &changed.terrain_triangles,
            &changed.blocker_triangles,
        };
        ++*values[field];
        VWB_EXPECT(!(diagnostics == changed));
    }

    TerrainTileGeometry geometry;
    TerrainCollisionBuild collision_build;
    VWB_EXPECT(!geometry.ready());
    VWB_EXPECT(!collision_build.ready());
    geometry.status = TerrainMeshingStatus::ready;
    collision_build.status = TerrainMeshingStatus::ready;
    VWB_EXPECT(geometry.ready());
    VWB_EXPECT(collision_build.ready());
}

VWB_TEST(terrain_meshing_region_contract_rejects_each_invalid_axis_and_overflow_side) {
    CellRegion required{};
    TerrainTileMeshRequest request = request_for(unit_cube_region());
    VWB_EXPECT_EQ(TerrainMeshingStatus::ready,
        required_terrain_sample_region(request, required));
    VWB_EXPECT_EQ(CellCoord({-1, -1, -1}), required.minimum);
    VWB_EXPECT_EQ(CellCoord({3, 3, 3}), required.maximum_exclusive);

    request.cell_size = -1.0;
    VWB_EXPECT_EQ(TerrainMeshingStatus::invalid_request,
        required_terrain_sample_region(request, required));
    request.cell_size = std::numeric_limits<double>::infinity();
    VWB_EXPECT_EQ(TerrainMeshingStatus::invalid_request,
        required_terrain_sample_region(request, required));

    const std::vector<CellRegion> invalid_regions = {
        {{0, 0, 0}, {0, 1, 1}},
        {{0, 0, 0}, {1, 0, 1}},
        {{0, 0, 0}, {1, 1, 0}},
    };
    for (const CellRegion &invalid : invalid_regions) {
        request = request_for(invalid);
        VWB_EXPECT_EQ(TerrainMeshingStatus::invalid_request,
            required_terrain_sample_region(request, required));
    }

    const std::int32_t minimum = std::numeric_limits<std::int32_t>::min();
    const std::int32_t maximum = std::numeric_limits<std::int32_t>::max();
    const std::vector<CellRegion> overflow_regions = {
        {{minimum, 0, 0}, {minimum + 1, 1, 1}},
        {{0, minimum, 0}, {1, minimum + 1, 1}},
        {{0, 0, minimum}, {1, 1, minimum + 1}},
        {{maximum - 1, 0, 0}, {maximum, 1, 1}},
        {{0, maximum - 1, 0}, {1, maximum, 1}},
        {{0, 0, maximum - 1}, {1, 1, maximum}},
    };
    for (const CellRegion &overflow : overflow_regions) {
        request = request_for(overflow);
        VWB_EXPECT_EQ(TerrainMeshingStatus::coordinate_overflow,
            required_terrain_sample_region(request, required));
    }

    request = request_for(unit_cube_region());
    VWB_EXPECT(terrain_tile_reads_cell(request, {-1, -1, -1}));
    VWB_EXPECT(terrain_tile_reads_cell(request, {2, 2, 2}));
    for (const CellCoord &outside : std::vector<CellCoord>{
             {-2, 0, 0}, {3, 0, 0}, {0, -2, 0}, {0, 3, 0}, {0, 0, -2}, {0, 0, 3}}) {
        VWB_EXPECT(!terrain_tile_reads_cell(request, outside));
    }
}

VWB_TEST(terrain_meshing_incomplete_halo_fails_closed_on_each_boundary) {
    const std::vector<CellRegion> incomplete_regions = {
        {{0, -1, -1}, {3, 3, 3}},
        {{-1, 0, -1}, {3, 3, 3}},
        {{-1, -1, 0}, {3, 3, 3}},
        {{-1, -1, -1}, {2, 3, 3}},
        {{-1, -1, -1}, {3, 2, 3}},
        {{-1, -1, -1}, {3, 3, 2}},
    };
    for (const CellRegion &region : incomplete_regions) {
        const TerrainSnapshot snapshot = snapshot_for(
            region, [](const CellCoord &) { return -1.0; });
        const TerrainTileGeometry geometry = build_terrain_tile_geometry(
            snapshot, request_for(unit_cube_region()));
        const TerrainCollisionBuild collision = build_terrain_collision(
            snapshot, request_for(unit_cube_region()));
        VWB_EXPECT_EQ(TerrainMeshingStatus::incomplete_halo, geometry.status);
        VWB_EXPECT_EQ(TerrainMeshingStatus::incomplete_halo, collision.status);
        VWB_EXPECT(!geometry.ready());
        VWB_EXPECT(!collision.ready());
        VWB_EXPECT(geometry.render.vertices.empty());
        VWB_EXPECT(geometry.collision.triangles.empty());
        VWB_EXPECT(collision.collision.triangles.empty());
    }
}

VWB_TEST(terrain_meshing_uses_plain_air_and_stone_fallback_for_water_solid) {
    const CellCoord corner0{0, 0, 0};
    std::vector<TerrainCell> cells = cells_for(
        unit_sample_region(), authority(),
        [corner0](const CellCoord &cell) { return cell == corner0 ? 1.0 : -1.0; });
    for (TerrainCell &cell : cells) {
        if (cell.solid) {
            cell.material = TerrainMaterialId::water;
        } else {
            cell.resolved_biome = TerrainBiomeId::plains;
        }
    }
    const TerrainSnapshot snapshot = TerrainSnapshot::create(
        descriptor(unit_sample_region()), std::move(cells), {});
    const TerrainTileGeometry geometry = build_terrain_tile_geometry(
        snapshot, request_for(unit_cube_region()));
    VWB_EXPECT(geometry.ready());
    VWB_EXPECT(!geometry.render.vertices.empty());
    for (const TerrainRenderVertex &vertex : geometry.render.vertices) {
        VWB_EXPECT_EQ(TerrainMaterialId::stone, vertex.material);
        VWB_EXPECT_EQ(TerrainBiomeId::plains, vertex.air_biome);
    }
}

VWB_TEST(terrain_meshing_extreme_terrain_and_blocker_coordinates_fail_closed) {
    const CellCoord corner0{0, 0, 0};
    const TerrainSnapshot terrain_snapshot = snapshot_for(
        unit_sample_region(),
        [corner0](const CellCoord &cell) { return cell == corner0 ? 1.0 : -1.0; });

    TerrainTileMeshRequest local_overflow = request_for(unit_cube_region());
    local_overflow.cell_size = std::numeric_limits<double>::max();
    local_overflow.local_origin.x = std::numeric_limits<std::int32_t>::min();
    const TerrainTileGeometry rejected_local = build_terrain_tile_geometry(
        terrain_snapshot, local_overflow);
    VWB_EXPECT_EQ(TerrainMeshingStatus::coordinate_overflow, rejected_local.status);
    VWB_EXPECT(!rejected_local.ready());
    VWB_EXPECT(rejected_local.render.vertices.empty());
    VWB_EXPECT(rejected_local.collision.triangles.empty());

    TerrainTileMeshRequest y_overflow = request_for({{0, 1, 0}, {1, 2, 1}});
    y_overflow.cell_size = std::numeric_limits<double>::max();
    const TerrainSnapshot elevated_snapshot = snapshot_for(
        {{-1, 0, -1}, {3, 4, 3}}, [](const CellCoord &) { return -1.0; });
    const TerrainTileGeometry rejected_y = build_terrain_tile_geometry(
        elevated_snapshot, y_overflow);
    VWB_EXPECT_EQ(TerrainMeshingStatus::coordinate_overflow, rejected_y.status);
    VWB_EXPECT(!rejected_y.ready());

    TerrainTileMeshRequest z_overflow = request_for(unit_cube_region());
    z_overflow.cell_size = std::numeric_limits<double>::max();
    z_overflow.local_origin.z = std::numeric_limits<std::int32_t>::min();
    const TerrainTileGeometry rejected_z = build_terrain_tile_geometry(
        terrain_snapshot, z_overflow);
    VWB_EXPECT_EQ(TerrainMeshingStatus::coordinate_overflow, rejected_z.status);
    VWB_EXPECT(!rejected_z.ready());

    TerrainTileMeshRequest face_overflow = request_for(unit_cube_region());
    face_overflow.cell_size = std::numeric_limits<double>::max();
    const TerrainTileGeometry rejected_face = build_terrain_tile_geometry(
        terrain_snapshot, face_overflow);
    const TerrainCollisionBuild rejected_collision = build_terrain_collision(
        terrain_snapshot, face_overflow);
    VWB_EXPECT_EQ(TerrainMeshingStatus::nonfinite_geometry, rejected_face.status);
    VWB_EXPECT_EQ(TerrainMeshingStatus::nonfinite_geometry, rejected_collision.status);
    VWB_EXPECT(!rejected_face.ready());
    VWB_EXPECT(!rejected_collision.ready());
    VWB_EXPECT(rejected_face.render.vertices.empty());
    VWB_EXPECT(rejected_face.collision.triangles.empty());
    VWB_EXPECT(rejected_collision.collision.triangles.empty());

    const DeclaredFeatureBlocker remote_blocker{
        "feature:coordinate-overflow",
        {std::numeric_limits<double>::max(), 0.5, 0.5},
        {0.5, 0.5, 0.5},
        "fixture_blocker",
        "blocks_motion",
    };
    const TerrainSnapshot blocker_snapshot = snapshot_for(
        unit_sample_region(), [](const CellCoord &) { return -1.0; }, {remote_blocker});
    const TerrainTileGeometry rejected_blocker = build_terrain_tile_geometry(
        blocker_snapshot, request_for(unit_cube_region()));
    VWB_EXPECT_EQ(TerrainMeshingStatus::coordinate_overflow, rejected_blocker.status);
    VWB_EXPECT(!rejected_blocker.ready());
    VWB_EXPECT(rejected_blocker.render.vertices.empty());
    VWB_EXPECT(rejected_blocker.collision.triangles.empty());

    const DeclaredFeatureBlocker negative_remote_blocker{
        "feature:negative-coordinate-overflow",
        {-std::numeric_limits<double>::max(), 0.5, 0.5},
        {0.5, 0.5, 0.5},
        "fixture_blocker",
        "blocks_motion",
    };
    const TerrainSnapshot negative_blocker_snapshot = snapshot_for(
        unit_sample_region(), [](const CellCoord &) { return -1.0; }, {negative_remote_blocker});
    VWB_EXPECT_EQ(TerrainMeshingStatus::coordinate_overflow,
        build_terrain_tile_geometry(negative_blocker_snapshot, request_for(unit_cube_region())).status);

    const DeclaredFeatureBlocker finite_division_overflow_blocker{
        "feature:finite-division-overflow",
        {0.5, 0.5, 0.5},
        {0.5, 0.5, 0.5},
        "fixture_blocker",
        "blocks_motion",
    };
    const TerrainSnapshot finite_division_snapshot = snapshot_for(
        unit_sample_region(), [](const CellCoord &) { return -1.0; }, {finite_division_overflow_blocker});
    TerrainTileMeshRequest tiny_cell_request = request_for(unit_cube_region());
    tiny_cell_request.cell_size = std::numeric_limits<double>::denorm_min();
    VWB_EXPECT_EQ(TerrainMeshingStatus::coordinate_overflow,
        build_terrain_tile_geometry(finite_division_snapshot, tiny_cell_request).status);

    const double maximum = std::numeric_limits<double>::max();
    const DeclaredFeatureBlocker negative_arithmetic_blocker{
        "feature:negative-arithmetic-overflow",
        {-maximum * 0.75, 0.5, 0.5},
        {maximum, 0.5, 0.5},
        "fixture_blocker",
        "blocks_motion",
    };
    const CellRegion negative_sample_region{{-2, -1, -1}, {2, 3, 3}};
    const TerrainSnapshot negative_arithmetic_snapshot = snapshot_for(
        negative_sample_region, [](const CellCoord &) { return -1.0; }, {negative_arithmetic_blocker});
    TerrainTileMeshRequest negative_owner_request = request_for({{-1, 0, 0}, {0, 1, 1}});
    negative_owner_request.cell_size = maximum;
    VWB_EXPECT_EQ(TerrainMeshingStatus::nonfinite_geometry,
        build_terrain_tile_geometry(negative_arithmetic_snapshot, negative_owner_request).status);

    const DeclaredFeatureBlocker face_normal_overflow_blocker{
        "feature:face-normal-overflow",
        {0.0, 0.0, 0.0},
        {maximum, maximum, maximum},
        "fixture_blocker",
        "blocks_motion",
    };
    const TerrainSnapshot face_normal_snapshot = snapshot_for(
        unit_sample_region(), [](const CellCoord &) { return -1.0; }, {face_normal_overflow_blocker});
    const TerrainTileGeometry rejected_face_normal = build_terrain_tile_geometry(
        face_normal_snapshot, request_for(unit_cube_region()));
    VWB_EXPECT_EQ(TerrainMeshingStatus::nonfinite_geometry, rejected_face_normal.status);
    VWB_EXPECT(rejected_face_normal.render.vertices.empty());
    VWB_EXPECT(rejected_face_normal.collision.triangles.empty());

    const DeclaredFeatureBlocker degenerate_blocker{
        "feature:underflow-degenerate",
        {0.5, 0.5, 0.5},
        {
            std::numeric_limits<double>::denorm_min(),
            std::numeric_limits<double>::denorm_min(),
            std::numeric_limits<double>::denorm_min(),
        },
        "fixture_blocker",
        "blocks_motion",
    };
    const TerrainSnapshot degenerate_blocker_snapshot = snapshot_for(
        unit_sample_region(), [](const CellCoord &) { return -1.0; }, {degenerate_blocker});
    const TerrainTileGeometry degenerate_blocker_geometry = build_terrain_tile_geometry(
        degenerate_blocker_snapshot, request_for(unit_cube_region()));
    VWB_EXPECT(degenerate_blocker_geometry.ready());
    VWB_EXPECT(degenerate_blocker_geometry.render.vertices.empty());
    VWB_EXPECT(degenerate_blocker_geometry.collision.triangles.empty());
    VWB_EXPECT_EQ(static_cast<std::size_t>(12),
        degenerate_blocker_geometry.diagnostics.rejected_degenerate_triangles);
}
