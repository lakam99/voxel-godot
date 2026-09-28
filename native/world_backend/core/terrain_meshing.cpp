#include "terrain_meshing.hpp"

#include "authority.hpp"
#include "coordinates.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <utility>

namespace voxel::world_backend {
namespace {

constexpr std::size_t CUBE_CORNER_COUNT = 8;
constexpr std::size_t TETRAHEDRON_COUNT = 6;
constexpr double ZERO_CROSSING_DENOMINATOR_EPSILON = 0.00001;
constexpr double DEGENERATE_NORMAL_SQUARED_EPSILON = 0.000001;

constexpr std::array<CellCoord, CUBE_CORNER_COUNT> CUBE_CORNERS = {{
    {0, 0, 0},
    {1, 0, 0},
    {1, 0, 1},
    {0, 0, 1},
    {0, 1, 0},
    {1, 1, 0},
    {1, 1, 1},
    {0, 1, 1},
}};

constexpr std::array<std::array<std::size_t, 4>, TETRAHEDRON_COUNT> TETRAHEDRA = {{
    {{0, 5, 1, 6}},
    {{0, 1, 2, 6}},
    {{0, 2, 3, 6}},
    {{0, 3, 7, 6}},
    {{0, 7, 4, 6}},
    {{0, 4, 5, 6}},
}};

bool finite(const Vec3d &value) noexcept {
    return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
}

Vec3d add(const Vec3d &left, const Vec3d &right) noexcept {
    return {left.x + right.x, left.y + right.y, left.z + right.z};
}

Vec3d subtract(const Vec3d &left, const Vec3d &right) noexcept {
    return {left.x - right.x, left.y - right.y, left.z - right.z};
}

Vec3d multiply(const Vec3d &value, const double factor) noexcept {
    return {value.x * factor, value.y * factor, value.z * factor};
}

Vec3d divide(const Vec3d &value, const double divisor) noexcept {
    return {value.x / divisor, value.y / divisor, value.z / divisor};
}

double dot(const Vec3d &left, const Vec3d &right) noexcept {
    return left.x * right.x + left.y * right.y + left.z * right.z;
}

Vec3d cross(const Vec3d &left, const Vec3d &right) noexcept {
    return {
        left.y * right.z - left.z * right.y,
        left.z * right.x - left.x * right.z,
        left.x * right.y - left.y * right.x,
    };
}

double length_squared(const Vec3d &value) noexcept {
    return dot(value, value);
}

Vec3d normalized(const Vec3d &value) noexcept {
    const double squared = length_squared(value);
    if (!std::isfinite(squared) || squared <= 0.0) {
        return {};
    }
    return divide(value, std::sqrt(squared));
}

Vec3d lerp(const Vec3d &from, const Vec3d &to, const double amount) noexcept {
    return add(from, multiply(subtract(to, from), amount));
}

TerrainMeshingStatus authority_status(
    const RequestAuthority &snapshot,
    const RequestAuthority &current) noexcept {
    constexpr std::array<TerrainMeshingStatus, 5> STATUS_BY_DECISION = {{
        TerrainMeshingStatus::ready,
        TerrainMeshingStatus::wrong_world,
        TerrainMeshingStatus::stale_owner,
        TerrainMeshingStatus::cancelled,
        TerrainMeshingStatus::stale_source,
    }};
    return STATUS_BY_DECISION[static_cast<std::size_t>(
        validate_result_authority(snapshot, current))];
}

bool valid_region(const CellRegion &region) noexcept {
    return region.maximum_exclusive.x > region.minimum.x &&
        region.maximum_exclusive.y > region.minimum.y &&
        region.maximum_exclusive.z > region.minimum.z;
}

bool contains_region(const CellRegion &outer, const CellRegion &inner) noexcept {
    return outer.minimum.x <= inner.minimum.x &&
        outer.minimum.y <= inner.minimum.y &&
        outer.minimum.z <= inner.minimum.z &&
        outer.maximum_exclusive.x >= inner.maximum_exclusive.x &&
        outer.maximum_exclusive.y >= inner.maximum_exclusive.y &&
        outer.maximum_exclusive.z >= inner.maximum_exclusive.z;
}

bool contains_cell(const CellRegion &region, const CellCoord &cell) noexcept {
    return cell.x >= region.minimum.x && cell.x < region.maximum_exclusive.x &&
        cell.y >= region.minimum.y && cell.y < region.maximum_exclusive.y &&
        cell.z >= region.minimum.z && cell.z < region.maximum_exclusive.z;
}

bool iteration_count_fits(const CellRegion &region) noexcept {
    const std::uint64_t x = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(region.maximum_exclusive.x) - region.minimum.x);
    const std::uint64_t y = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(region.maximum_exclusive.y) - region.minimum.y);
    const std::uint64_t z = static_cast<std::uint64_t>(
        static_cast<std::int64_t>(region.maximum_exclusive.z) - region.minimum.z);
    // required_terrain_sample_region has already established positive int32
    // extents, whose X*Y product fits the uint64_t target used by this core.
    const std::size_t xy = static_cast<std::size_t>(x * y);
    return z <= std::numeric_limits<std::size_t>::max() / xy;
}

void offset_cell(
    const CellCoord &cell,
    const CellCoord &offset,
    CellCoord &result) noexcept {
    // The validated source halo guarantees that every cube corner remains in
    // int32 range; perform the addition wide to keep that invariant explicit.
    result = {
        static_cast<std::int32_t>(static_cast<std::int64_t>(cell.x) + offset.x),
        static_cast<std::int32_t>(static_cast<std::int64_t>(cell.y) + offset.y),
        static_cast<std::int32_t>(static_cast<std::int64_t>(cell.z) + offset.z),
    };
}

bool local_position(
    const CellCoord &cell,
    const TerrainTileMeshRequest &request,
    Vec3d &result) noexcept {
    const std::int64_t dx = static_cast<std::int64_t>(cell.x) - request.local_origin.x;
    const std::int64_t dz = static_cast<std::int64_t>(cell.z) - request.local_origin.z;
    result = {
        static_cast<double>(dx) * request.cell_size,
        static_cast<double>(cell.y) * request.cell_size,
        static_cast<double>(dz) * request.cell_size,
    };
    return finite(result);
}

Vec3d world_position(const CellCoord &cell, const double cell_size) noexcept {
    return {
        static_cast<double>(cell.x) * cell_size,
        static_cast<double>(cell.y) * cell_size,
        static_cast<double>(cell.z) * cell_size,
    };
}

double zero_crossing_t(const double density_a, const double density_b) noexcept {
    const double denominator = density_a - density_b;
    double amount = 0.5;
    if (std::abs(denominator) > ZERO_CROSSING_DENOMINATOR_EPSILON) {
        amount = density_a / denominator;
    }
    return std::clamp(amount, 0.0, 1.0);
}

Vec3d interpolate_zero_crossing(
    const Vec3d &a,
    const Vec3d &b,
    const double density_a,
    const double density_b) noexcept {
    return lerp(a, b, zero_crossing_t(density_a, density_b));
}

Vec3d surface_normal_from_density_gradient(
    const Vec3d &gradient,
    const Vec3d &desired_direction,
    const Vec3d &fallback) noexcept {
    Vec3d normal = multiply(gradient, -1.0);
    if (length_squared(normal) <= DEGENERATE_NORMAL_SQUARED_EPSILON) {
        normal = fallback;
    }
    // Mixed tetrahedra provide a nonzero solid-to-air fallback, and emitted
    // blocker faces provide a previously accepted nondegenerate face normal.
    normal = normalized(normal);
    if (dot(normal, desired_direction) < 0.0) {
        normal = multiply(normal, -1.0);
    }
    return normal;
}

Vec3d interpolate_zero_crossing_normal(
    const Vec3d &gradient_a,
    const Vec3d &gradient_b,
    const double density_a,
    const double density_b,
    const Vec3d &desired_direction) noexcept {
    const Vec3d gradient = lerp(
        gradient_a,
        gradient_b,
        zero_crossing_t(density_a, density_b));
    return surface_normal_from_density_gradient(
        gradient,
        desired_direction,
        desired_direction);
}

TerrainMaterialId select_surface_material(
    const std::array<const TerrainCell *, CUBE_CORNER_COUNT> &samples,
    const std::array<std::size_t, 4> &solid_indices,
    const std::size_t solid_count) noexcept {
    for (std::size_t index = 0; index < solid_count; ++index) {
        const TerrainMaterialId material = samples[solid_indices[index]]->material;
        // Snapshot validation prevents a solid sample from using air.
        if (material != TerrainMaterialId::water && material != TerrainMaterialId::lava) {
            return material;
        }
    }
    return TerrainMaterialId::stone;
}

TerrainBiomeId select_air_biome(
    const std::array<const TerrainCell *, CUBE_CORNER_COUNT> &samples,
    const std::array<std::size_t, 4> &air_indices,
    const std::size_t air_count) noexcept {
    TerrainBiomeId selected = samples[air_indices[0]]->resolved_biome;
    for (std::size_t index = 0; index < air_count; ++index) {
        if (samples[air_indices[index]]->resolved_biome == TerrainBiomeId::underground_air) {
            return TerrainBiomeId::underground_air;
        }
    }
    return selected;
}

struct BuildState {
    TerrainMeshingStatus status = TerrainMeshingStatus::ready;
    bool include_render = false;
    TerrainRenderInputs render;
    TerrainCollisionInputs collision;
    TerrainMeshingDiagnostics diagnostics;
};

void append_oriented_triangle(
    BuildState &state,
    Vec3d a,
    Vec3d b,
    Vec3d c,
    Vec3d normal_a,
    Vec3d normal_b,
    Vec3d normal_c,
    const Vec3d &solid_reference,
    const Vec3d &air_reference,
    const TerrainMaterialId material,
    const TerrainBiomeId air_biome,
    const TerrainSurfaceSource source,
    const std::string &source_id) {
    Vec3d face_normal = cross(subtract(b, a), subtract(c, a));
    if (!finite(face_normal)) {
        state.status = TerrainMeshingStatus::nonfinite_geometry;
        return;
    }
    if (length_squared(face_normal) <= DEGENERATE_NORMAL_SQUARED_EPSILON) {
        ++state.diagnostics.rejected_degenerate_triangles;
        return;
    }
    face_normal = normalized(face_normal);
    const Vec3d desired = subtract(air_reference, solid_reference);
    if (dot(face_normal, desired) < 0.0) {
        std::swap(b, c);
        std::swap(normal_b, normal_c);
        face_normal = multiply(face_normal, -1.0);
    }
    // The existing native implementation passes already-oriented interpolated
    // normals through the same fallback/orientation rule once more.
    normal_a = surface_normal_from_density_gradient(multiply(normal_a, -1.0), desired, face_normal);
    normal_b = surface_normal_from_density_gradient(multiply(normal_b, -1.0), desired, face_normal);
    normal_c = surface_normal_from_density_gradient(multiply(normal_c, -1.0), desired, face_normal);
    state.collision.triangles.push_back({{{a, b, c}}, source, source_id});
    if (state.include_render) {
        state.render.vertices.push_back({a, normal_a, material, air_biome, source, source_id});
        state.render.vertices.push_back({b, normal_b, material, air_biome, source, source_id});
        state.render.vertices.push_back({c, normal_c, material, air_biome, source, source_id});
    }
    if (source == TerrainSurfaceSource::terrain) {
        ++state.diagnostics.terrain_triangles;
    } else {
        ++state.diagnostics.blocker_triangles;
    }
}

Vec3d average_positions(
    const std::array<Vec3d, CUBE_CORNER_COUNT> &positions,
    const std::array<std::size_t, 4> &indices,
    const std::size_t count) noexcept {
    Vec3d result{};
    for (std::size_t index = 0; index < count; ++index) {
        result = add(result, positions[indices[index]]);
    }
    return divide(result, static_cast<double>(count));
}

void append_tetrahedron_surface(
    BuildState &state,
    const std::array<Vec3d, CUBE_CORNER_COUNT> &local_positions,
    const std::array<Vec3d, CUBE_CORNER_COUNT> &world_positions,
    const std::array<double, CUBE_CORNER_COUNT> &densities,
    const std::array<Vec3d, CUBE_CORNER_COUNT> &density_gradients,
    const std::array<Vec3d, CUBE_CORNER_COUNT> &surface_gradients,
    const std::array<const TerrainCell *, CUBE_CORNER_COUNT> &samples,
    const std::array<std::size_t, 4> &tetrahedron,
    const double cell_size) {
    std::array<std::size_t, 4> solid_indices{};
    std::array<std::size_t, 4> air_indices{};
    std::size_t solid_count = 0;
    std::size_t air_count = 0;
    for (const std::size_t corner : tetrahedron) {
        if (densities[corner] >= 0.0) {
            solid_indices[solid_count++] = corner;
        } else {
            air_indices[air_count++] = corner;
        }
    }
    if (solid_count == 0 || air_count == 0) {
        return;
    }

    const Vec3d solid_reference = average_positions(local_positions, solid_indices, solid_count);
    const Vec3d air_reference = average_positions(local_positions, air_indices, air_count);
    const Vec3d solid_world_reference = average_positions(world_positions, solid_indices, solid_count);
    const Vec3d air_world_reference = average_positions(world_positions, air_indices, air_count);
    double surface_y = 0.0;
    for (const std::size_t corner : tetrahedron) {
        surface_y += samples[corner]->surface_y;
    }
    surface_y /= 4.0;
    const double world_y = (solid_world_reference.y + air_world_reference.y) * 0.5;
    const double depth_cells = (surface_y - world_y) / std::max(0.001, cell_size);
    const TerrainMaterialId material = select_surface_material(samples, solid_indices, solid_count);
    const TerrainBiomeId air_biome = select_air_biome(samples, air_indices, air_count);
    const bool use_volume_normals =
        air_biome == TerrainBiomeId::underground_air && depth_cells > 2.5;
    const auto &normal_gradients = use_volume_normals ? density_gradients : surface_gradients;
    const Vec3d desired = subtract(air_reference, solid_reference);

    auto point = [&](const std::size_t a, const std::size_t b) {
        return interpolate_zero_crossing(
            local_positions[a], local_positions[b], densities[a], densities[b]);
    };
    auto normal = [&](const std::size_t a, const std::size_t b) {
        return interpolate_zero_crossing_normal(
            normal_gradients[a], normal_gradients[b], densities[a], densities[b], desired);
    };

    if (solid_count == 1) {
        const std::size_t s0 = solid_indices[0];
        append_oriented_triangle(
            state,
            point(s0, air_indices[0]), point(s0, air_indices[1]), point(s0, air_indices[2]),
            normal(s0, air_indices[0]), normal(s0, air_indices[1]), normal(s0, air_indices[2]),
            solid_reference, air_reference, material, air_biome,
            TerrainSurfaceSource::terrain, {});
        return;
    }
    if (solid_count == 3) {
        const std::size_t a0 = air_indices[0];
        append_oriented_triangle(
            state,
            point(a0, solid_indices[0]), point(a0, solid_indices[2]), point(a0, solid_indices[1]),
            normal(a0, solid_indices[0]), normal(a0, solid_indices[2]), normal(a0, solid_indices[1]),
            solid_reference, air_reference, material, air_biome,
            TerrainSurfaceSource::terrain, {});
        return;
    }

    const std::size_t s0 = solid_indices[0];
    const std::size_t s1 = solid_indices[1];
    const std::size_t a0 = air_indices[0];
    const std::size_t a1 = air_indices[1];
    const Vec3d p00 = point(s0, a0);
    const Vec3d p01 = point(s0, a1);
    const Vec3d p10 = point(s1, a0);
    const Vec3d p11 = point(s1, a1);
    const Vec3d n00 = normal(s0, a0);
    const Vec3d n01 = normal(s0, a1);
    const Vec3d n10 = normal(s1, a0);
    const Vec3d n11 = normal(s1, a1);
    append_oriented_triangle(
        state, p00, p10, p11, n00, n10, n11,
        solid_reference, air_reference, material, air_biome,
        TerrainSurfaceSource::terrain, {});
    append_oriented_triangle(
        state, p00, p11, p01, n00, n11, n01,
        solid_reference, air_reference, material, air_biome,
        TerrainSurfaceSource::terrain, {});
}

bool cell_for_world_position(
    const Vec3d &position,
    const double cell_size,
    CellCoord &cell) noexcept {
    const std::array<double, 3> values = {
        std::floor(position.x / cell_size),
        std::floor(position.y / cell_size),
        std::floor(position.z / cell_size),
    };
    for (const double value : values) {
        if (!std::isfinite(value) ||
            value < std::numeric_limits<std::int32_t>::min() ||
            value > std::numeric_limits<std::int32_t>::max()) {
            return false;
        }
    }
    cell = {
        static_cast<std::int32_t>(values[0]),
        static_cast<std::int32_t>(values[1]),
        static_cast<std::int32_t>(values[2]),
    };
    return true;
}

void append_blocker(
    BuildState &state,
    const DeclaredFeatureBlocker &blocker,
    const TerrainTileMeshRequest &request) {
    CellCoord owner_cell{};
    if (!cell_for_world_position(blocker.center, request.cell_size, owner_cell)) {
        state.status = TerrainMeshingStatus::coordinate_overflow;
        return;
    }
    if (!contains_cell(request.owned_cube_region, owner_cell)) {
        return;
    }

    const Vec3d local_origin_world = world_position(request.local_origin, request.cell_size);
    const Vec3d center = subtract(blocker.center, local_origin_world);
    const Vec3d half = multiply(blocker.size, 0.5);
    const Vec3d minimum = subtract(center, half);
    const Vec3d maximum = add(center, half);
    if (!finite(minimum) || !finite(maximum)) {
        state.status = TerrainMeshingStatus::nonfinite_geometry;
        return;
    }
    const std::array<Vec3d, 8> points = {{
        {minimum.x, minimum.y, minimum.z},
        {maximum.x, minimum.y, minimum.z},
        {maximum.x, maximum.y, minimum.z},
        {minimum.x, maximum.y, minimum.z},
        {minimum.x, minimum.y, maximum.z},
        {maximum.x, minimum.y, maximum.z},
        {maximum.x, maximum.y, maximum.z},
        {minimum.x, maximum.y, maximum.z},
    }};
    constexpr std::array<std::array<std::size_t, 3>, 12> FACES = {{
        {{0, 2, 1}}, {{0, 3, 2}},
        {{4, 5, 6}}, {{4, 6, 7}},
        {{0, 4, 7}}, {{0, 7, 3}},
        {{1, 2, 6}}, {{1, 6, 5}},
        {{0, 1, 5}}, {{0, 5, 4}},
        {{3, 7, 6}}, {{3, 6, 2}},
    }};
    for (const auto &face : FACES) {
        const Vec3d a = points[face[0]];
        const Vec3d b = points[face[1]];
        const Vec3d c = points[face[2]];
        const Vec3d face_center = divide(add(add(a, b), c), 3.0);
        const Vec3d desired = subtract(face_center, center);
        const Vec3d normal = normalized(cross(subtract(b, a), subtract(c, a)));
        append_oriented_triangle(
            state, a, b, c, normal, normal, normal,
            center, add(center, desired), TerrainMaterialId::stone,
            TerrainBiomeId::plains, TerrainSurfaceSource::declared_feature_blocker,
            blocker.stable_id);
        if (state.status != TerrainMeshingStatus::ready) {
            return;
        }
    }
}

BuildState build_impl(
    const TerrainSnapshot &snapshot,
    const TerrainTileMeshRequest &request,
    const bool include_render) {
    BuildState state;
    state.include_render = include_render;
    state.status = authority_status(snapshot.descriptor().authority, request.current_authority);
    if (state.status != TerrainMeshingStatus::ready) {
        return state;
    }
    CellRegion required{};
    state.status = required_terrain_sample_region(request, required);
    if (state.status != TerrainMeshingStatus::ready) {
        return state;
    }
    if (!iteration_count_fits(request.owned_cube_region)) {
        state.status = TerrainMeshingStatus::coordinate_overflow;
        return state;
    }
    if (!contains_region(snapshot.sample_region(), required)) {
        state.status = TerrainMeshingStatus::incomplete_halo;
        return state;
    }

    for (std::int64_t z64 = request.owned_cube_region.minimum.z;
         z64 < request.owned_cube_region.maximum_exclusive.z; ++z64) {
        for (std::int64_t x64 = request.owned_cube_region.minimum.x;
             x64 < request.owned_cube_region.maximum_exclusive.x; ++x64) {
            for (std::int64_t y64 = request.owned_cube_region.minimum.y;
                 y64 < request.owned_cube_region.maximum_exclusive.y; ++y64) {
                const CellCoord origin{
                    static_cast<std::int32_t>(x64),
                    static_cast<std::int32_t>(y64),
                    static_cast<std::int32_t>(z64),
                };
                ++state.diagnostics.visited_cubes;
                std::array<CellCoord, CUBE_CORNER_COUNT> corner_cells{};
                std::array<const TerrainCell *, CUBE_CORNER_COUNT> samples{};
                std::array<Vec3d, CUBE_CORNER_COUNT> local_positions{};
                std::array<Vec3d, CUBE_CORNER_COUNT> world_positions{};
                std::array<double, CUBE_CORNER_COUNT> densities{};
                std::array<Vec3d, CUBE_CORNER_COUNT> density_gradients{};
                std::array<Vec3d, CUBE_CORNER_COUNT> surface_gradients{};
                bool has_solid = false;
                bool has_air = false;
                for (std::size_t index = 0; index < CUBE_CORNER_COUNT; ++index) {
                    offset_cell(origin, CUBE_CORNERS[index], corner_cells[index]);
                    if (!local_position(corner_cells[index], request, local_positions[index])) {
                        state.status = TerrainMeshingStatus::coordinate_overflow;
                        return state;
                    }
                    world_positions[index] = world_position(corner_cells[index], request.cell_size);
                    samples[index] = &snapshot.at(corner_cells[index]);
                    densities[index] = samples[index]->density;
                    has_solid = has_solid || densities[index] >= 0.0;
                    has_air = has_air || densities[index] < 0.0;
                }
                if (!has_solid || !has_air) {
                    continue;
                }
                ++state.diagnostics.mixed_cubes;
                if (include_render) {
                    for (std::size_t index = 0; index < CUBE_CORNER_COUNT; ++index) {
                        const CellCoord cell = corner_cells[index];
                        const TerrainCell &xp = snapshot.at({cell.x + 1, cell.y, cell.z});
                        const TerrainCell &xm = snapshot.at({cell.x - 1, cell.y, cell.z});
                        const TerrainCell &yp = snapshot.at({cell.x, cell.y + 1, cell.z});
                        const TerrainCell &ym = snapshot.at({cell.x, cell.y - 1, cell.z});
                        const TerrainCell &zp = snapshot.at({cell.x, cell.y, cell.z + 1});
                        const TerrainCell &zm = snapshot.at({cell.x, cell.y, cell.z - 1});
                        density_gradients[index] = {
                            xp.density - xm.density,
                            yp.density - ym.density,
                            zp.density - zm.density,
                        };
                        surface_gradients[index] = {
                            xp.surface_y - xm.surface_y,
                            -2.0 * request.cell_size,
                            zp.surface_y - zm.surface_y,
                        };
                    }
                }
                for (const auto &tetrahedron : TETRAHEDRA) {
                    append_tetrahedron_surface(
                        state, local_positions, world_positions, densities,
                        density_gradients, surface_gradients, samples, tetrahedron,
                        request.cell_size);
                    if (state.status != TerrainMeshingStatus::ready) {
                        return state;
                    }
                }
            }
        }
    }
    for (const DeclaredFeatureBlocker &blocker : snapshot.blockers()) {
        append_blocker(state, blocker, request);
        if (state.status != TerrainMeshingStatus::ready) {
            return state;
        }
    }
    return state;
}

} // namespace

bool TerrainRenderVertex::operator==(const TerrainRenderVertex &other) const noexcept {
    return position == other.position && normal == other.normal &&
        material == other.material && air_biome == other.air_biome &&
        source == other.source && source_id == other.source_id;
}

std::size_t TerrainRenderInputs::triangle_count() const noexcept {
    return vertices.size() / 3U;
}

bool TerrainRenderInputs::operator==(const TerrainRenderInputs &other) const noexcept {
    return vertices == other.vertices;
}

bool TerrainCollisionTriangle::operator==(const TerrainCollisionTriangle &other) const noexcept {
    return positions == other.positions && source == other.source && source_id == other.source_id;
}

std::size_t TerrainCollisionInputs::face_vertex_count() const noexcept {
    return triangles.size() * 3U;
}

bool TerrainCollisionInputs::operator==(const TerrainCollisionInputs &other) const noexcept {
    return triangles == other.triangles;
}

bool TerrainMeshingDiagnostics::operator==(const TerrainMeshingDiagnostics &other) const noexcept {
    return visited_cubes == other.visited_cubes &&
        mixed_cubes == other.mixed_cubes &&
        rejected_degenerate_triangles == other.rejected_degenerate_triangles &&
        terrain_triangles == other.terrain_triangles &&
        blocker_triangles == other.blocker_triangles;
}

bool TerrainTileGeometry::ready() const noexcept {
    return status == TerrainMeshingStatus::ready;
}

bool TerrainCollisionBuild::ready() const noexcept {
    return status == TerrainMeshingStatus::ready;
}

TerrainMeshingStatus required_terrain_sample_region(
    const TerrainTileMeshRequest &request,
    CellRegion &region_out) noexcept {
    if (request.detail_level != 0 || request.lod_level != 0 || request.step_cells != 1) {
        return TerrainMeshingStatus::unsupported_detail;
    }
    if (!std::isfinite(request.cell_size) || request.cell_size <= 0.0 ||
        request.local_origin.y != 0 ||
        !valid_region(request.owned_cube_region)) {
        return TerrainMeshingStatus::invalid_request;
    }
    const auto min_x = checked_add(request.owned_cube_region.minimum.x, -1);
    const auto min_y = checked_add(request.owned_cube_region.minimum.y, -1);
    const auto min_z = checked_add(request.owned_cube_region.minimum.z, -1);
    const auto max_x = checked_add(request.owned_cube_region.maximum_exclusive.x, 2);
    const auto max_y = checked_add(request.owned_cube_region.maximum_exclusive.y, 2);
    const auto max_z = checked_add(request.owned_cube_region.maximum_exclusive.z, 2);
    if (!min_x || !min_y || !min_z || !max_x || !max_y || !max_z) {
        return TerrainMeshingStatus::coordinate_overflow;
    }
    region_out = {{*min_x, *min_y, *min_z}, {*max_x, *max_y, *max_z}};
    return TerrainMeshingStatus::ready;
}

bool terrain_tile_reads_cell(
    const TerrainTileMeshRequest &request,
    const CellCoord &cell) noexcept {
    CellRegion required{};
    return required_terrain_sample_region(request, required) == TerrainMeshingStatus::ready &&
        contains_cell(required, cell);
}

TerrainTileGeometry build_terrain_tile_geometry(
    const TerrainSnapshot &snapshot,
    const TerrainTileMeshRequest &request) {
    BuildState state = build_impl(snapshot, request, true);
    TerrainTileGeometry result;
    result.status = state.status;
    result.snapshot_digest = snapshot.digest();
    if (state.status == TerrainMeshingStatus::ready) {
        result.render = std::move(state.render);
        result.collision = std::move(state.collision);
    }
    result.diagnostics = state.diagnostics;
    return result;
}

TerrainCollisionBuild build_terrain_collision(
    const TerrainSnapshot &snapshot,
    const TerrainTileMeshRequest &request) {
    BuildState state = build_impl(snapshot, request, false);
    TerrainCollisionBuild result;
    result.status = state.status;
    result.snapshot_digest = snapshot.digest();
    if (state.status == TerrainMeshingStatus::ready) {
        result.collision = std::move(state.collision);
    }
    result.diagnostics = state.diagnostics;
    return result;
}

} // namespace voxel::world_backend
