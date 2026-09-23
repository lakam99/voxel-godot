#include "native_surface_ore_footprint.hpp"

#include <algorithm>
#include <cmath>

namespace voxel::world_backend {
namespace {
NativeFeatureWorldBounds render_bounds(const NativeSurfaceOreChildDefinition &child) {
    const double x = child.world_anchor.x, y = child.world_anchor.y, z = child.world_anchor.z;
    NativeFeatureWorldBounds bounds{x, y, z, x, y, z};
    // The stone SphereMesh is centered at mesh_center_y. Its arbitrary body
    // yaw cannot exceed the larger scaled horizontal radius.
    const double stone_horizontal = static_cast<double>(child.mesh_radius)
        * std::max(child.mesh_scale.x, child.mesh_scale.z);
    const double stone_vertical = static_cast<double>(child.mesh_height) * child.mesh_scale.y * 0.5;
    native_feature_bounds_include_sphere(bounds, x, y + child.mesh_center_y, z,
        std::max(stone_horizontal, stone_vertical));
    // A circumscribed sphere encloses every seam box under its three local
    // rotations and the body's yaw; the same rule encloses scaled glints.
    const double seam_radius = 0.5 * std::sqrt(
        child.seam_mesh_size.x * child.seam_mesh_size.x
        + child.seam_mesh_size.y * child.seam_mesh_size.y
        + child.seam_mesh_size.z * child.seam_mesh_size.z);
    for (const auto &seam : child.seams)
        native_feature_bounds_include_sphere(bounds, x + seam.local_position.x, y + seam.local_position.y,
            z + seam.local_position.z, seam_radius);
    for (const auto &glint : child.glints)
        native_feature_bounds_include_sphere(bounds, x + glint.local_position.x, y + glint.local_position.y,
            z + glint.local_position.z, std::max(static_cast<double>(child.glint_mesh_radius)
                * std::max(glint.scale.x, glint.scale.z),
                static_cast<double>(child.glint_mesh_height) * glint.scale.y * 0.5));
    // Rotating all local centers around the body origin may move them farther
    // than their unrotated X/Z coordinates. Enclose the whole local XZ radius.
    native_feature_bounds_enclose_body_yaw(bounds, x, z);
    return bounds;
}
} // namespace

std::vector<NativeFeatureFootprintRun> native_surface_ore_child_footprint_runs(
    const NativeSurfaceOreChildDefinition &child, const double cell_size) {
    if (!child.present) return {};
    auto runs = native_feature_runs_for_bounds(render_bounds(child), cell_size,
        NativeFeatureFootprintChannel::render);
    const double x = child.world_anchor.x, y = child.world_anchor.y + child.collider_center_y;
    const double z = child.world_anchor.z, radius = child.collider_radius;
    const NativeFeatureWorldBounds physical{x-radius, y-radius, z-radius, x+radius, y+radius, z+radius};
    for (const auto channel : {NativeFeatureFootprintChannel::collision,
            NativeFeatureFootprintChannel::navigation}) {
        const auto physical_runs = native_feature_runs_for_bounds(physical, cell_size, channel);
        runs.insert(runs.end(), physical_runs.begin(), physical_runs.end());
    }
    return runs;
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
        entry.runs = native_surface_ore_child_footprint_runs(child, cell_size);
        entries.push_back(std::move(entry));
    }
    return NativeGeneratedFeatureFootprintCatalog::create(
        terrain.pin().physical_content_identity().digest,
        NativeSurfaceOreClusterDefinition::SCHEMA_REVISION, std::move(entries));
}

} // namespace voxel::world_backend
