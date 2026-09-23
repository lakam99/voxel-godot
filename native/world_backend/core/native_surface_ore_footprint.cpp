#include "native_surface_ore_footprint.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace voxel::world_backend {
namespace {
[[noreturn]] void reject() { throw NativeSurfaceOreFootprintRejected(); }

void include_sphere(NativeOreWorldBounds &bounds, const double x, const double y, const double z,
    const double radius) {
    bounds.min_x = std::min(bounds.min_x, x - radius);
    bounds.min_y = std::min(bounds.min_y, y - radius);
    bounds.min_z = std::min(bounds.min_z, z - radius);
    bounds.max_x = std::max(bounds.max_x, x + radius);
    bounds.max_y = std::max(bounds.max_y, y + radius);
    bounds.max_z = std::max(bounds.max_z, z + radius);
}

std::int32_t cell_for(const double position, const double cell_size) {
    const double cell = std::floor(position / cell_size);
    if (!std::isfinite(cell) || cell < std::numeric_limits<std::int32_t>::min()
        || cell > std::numeric_limits<std::int32_t>::max()) reject();
    return static_cast<std::int32_t>(cell);
}

std::vector<NativeFeatureFootprintRun> quantize_runs(
    const NativeOreWorldBounds &bounds, const double cell_size,
    const NativeFeatureFootprintChannel channel) {
    if (!std::isfinite(cell_size) || cell_size <= 0.0) reject();
    const auto x0 = cell_for(bounds.min_x, cell_size);
    const auto x1 = cell_for(bounds.max_x, cell_size);
    const auto y0 = cell_for(bounds.min_y, cell_size);
    const auto y1 = cell_for(bounds.max_y, cell_size);
    const auto z0 = cell_for(bounds.min_z, cell_size);
    const auto z1 = cell_for(bounds.max_z, cell_size);
    const std::int64_t rows_y = static_cast<std::int64_t>(y1) - y0 + 1LL;
    const std::int64_t rows_z = static_cast<std::int64_t>(z1) - z0 + 1LL;
    if (x0 > x1 || rows_y <= 0 || rows_z <= 0
        || rows_y > 4096LL || rows_z > 4096LL || rows_y * rows_z > 4096LL) reject();
    std::vector<NativeFeatureFootprintRun> runs;
    for (std::int64_t z = z0; z <= z1; ++z)
        for (std::int64_t y = y0; y <= y1; ++y)
            runs.push_back({channel, {x0, static_cast<std::int32_t>(y), static_cast<std::int32_t>(z)}, x1});
    return runs;
}

NativeOreWorldBounds render_bounds(const NativeSurfaceOreChildDefinition &child) {
    const double x = child.world_anchor.x, y = child.world_anchor.y, z = child.world_anchor.z;
    NativeOreWorldBounds bounds{x, y, z, x, y, z};
    // The stone SphereMesh is centered at mesh_center_y. Its arbitrary body
    // yaw cannot exceed the larger scaled horizontal radius.
    const double stone_horizontal = static_cast<double>(child.mesh_radius)
        * std::max(child.mesh_scale.x, child.mesh_scale.z);
    const double stone_vertical = static_cast<double>(child.mesh_height) * child.mesh_scale.y * 0.5;
    include_sphere(bounds, x, y + child.mesh_center_y, z,
        std::max(stone_horizontal, stone_vertical));
    // A circumscribed sphere encloses every seam box under its three local
    // rotations and the body's yaw; the same rule encloses scaled glints.
    const double seam_radius = 0.5 * std::sqrt(
        child.seam_mesh_size.x * child.seam_mesh_size.x
        + child.seam_mesh_size.y * child.seam_mesh_size.y
        + child.seam_mesh_size.z * child.seam_mesh_size.z);
    for (const auto &seam : child.seams)
        include_sphere(bounds, x + seam.local_position.x, y + seam.local_position.y,
            z + seam.local_position.z, seam_radius);
    for (const auto &glint : child.glints)
        include_sphere(bounds, x + glint.local_position.x, y + glint.local_position.y,
            z + glint.local_position.z, std::max(static_cast<double>(child.glint_mesh_radius)
                * std::max(glint.scale.x, glint.scale.z),
                static_cast<double>(child.glint_mesh_height) * glint.scale.y * 0.5));
    // Rotating all local centers around the body origin may move them farther
    // than their unrotated X/Z coordinates. Enclose the whole local XZ radius.
    const double far_x = std::max(std::abs(bounds.min_x - x), std::abs(bounds.max_x - x));
    const double far_z = std::max(std::abs(bounds.min_z - z), std::abs(bounds.max_z - z));
    const double outer = std::hypot(far_x, far_z);
    bounds.min_x = x - outer; bounds.max_x = x + outer;
    bounds.min_z = z - outer; bounds.max_z = z + outer;
    return bounds;
}
} // namespace

NativeSurfaceOreFootprintRejected::NativeSurfaceOreFootprintRejected()
    : std::invalid_argument("invalid source-bound ore footprint") {}

std::vector<NativeFeatureFootprintRun> native_surface_ore_runs_for_bounds(
    const NativeOreWorldBounds bounds, const double cell_size,
    const NativeFeatureFootprintChannel channel) {
    return quantize_runs(bounds, cell_size, channel);
}

NativeGeneratedFeatureFootprintCatalog compose_native_surface_ore_footprints(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements, const std::uint32_t ordinal,
    const NativeEffectiveTerrainSource &terrain) {
    const auto definition = NativeSurfaceOreClusterDefinition::create(ordered, placements, ordinal, terrain);
    const double cell_size = terrain.pin().definition().constants().cell_size_meters;
    std::vector<NativeGeneratedFeatureFootprintEntry> entries;
    for (const auto &child : definition.children()) {
        if (!child.present) continue;
        NativeGeneratedFeatureFootprintEntry entry;
        entry.feature_id = child.durable_id;
        entry.recipe_key = "surface_ore_cluster";
        entry.recipe_revision = NativeSurfaceOreClusterDefinition::SCHEMA_REVISION;
        entry.footprint_schema_revision = 1U;
        entry.generated_definition_digest = definition.content_digest();
        const auto visual = native_surface_ore_runs_for_bounds(render_bounds(child), cell_size,
            NativeFeatureFootprintChannel::render);
        entry.runs.insert(entry.runs.end(), visual.begin(), visual.end());
        const double x = child.world_anchor.x, y = child.world_anchor.y + child.collider_center_y;
        const double z = child.world_anchor.z, radius = child.collider_radius;
        const NativeOreWorldBounds physical{x-radius, y-radius, z-radius, x+radius, y+radius, z+radius};
        for (const auto channel : {NativeFeatureFootprintChannel::collision,
                NativeFeatureFootprintChannel::navigation}) {
            const auto runs = native_surface_ore_runs_for_bounds(physical, cell_size, channel);
            entry.runs.insert(entry.runs.end(), runs.begin(), runs.end());
        }
        entries.push_back(std::move(entry));
    }
    return NativeGeneratedFeatureFootprintCatalog::create(
        terrain.pin().physical_content_identity().digest,
        NativeSurfaceOreClusterDefinition::SCHEMA_REVISION, std::move(entries));
}

} // namespace voxel::world_backend
