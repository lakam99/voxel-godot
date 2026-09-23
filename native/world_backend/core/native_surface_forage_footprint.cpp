#include "native_surface_forage_footprint.hpp"

#include <algorithm>
#include <cmath>

namespace voxel::world_backend {
namespace {
NativeFeatureWorldBounds render_bounds(const NativeSurfaceForageOrderedDefinition &forage) {
    const auto &anchor = forage.placement().world_anchor;
    const double x = anchor.x, y = anchor.y, z = anchor.z;
    NativeFeatureWorldBounds bounds{x, y, z, x, y, z};
    for (const auto &mesh : forage.meshes()) {
        const double horizontal = mesh.kind == NativeForageMeshKind::sphere
            ? mesh.radius : std::max(mesh.top_radius, mesh.bottom_radius);
        // Circumscribe the scaled mesh before its local Euler rotation. The
        // body yaw is enclosed after all local meshes have contributed.
        const double radius = std::sqrt(
            std::pow(horizontal * mesh.scale.x, 2.0)
            + std::pow(mesh.height * mesh.scale.y * 0.5, 2.0)
            + std::pow(horizontal * mesh.scale.z, 2.0));
        native_feature_bounds_include_sphere(bounds,
            x + mesh.position.x, y + mesh.position.y, z + mesh.position.z, radius);
    }
    native_feature_bounds_enclose_body_yaw(bounds, x, z);
    return bounds;
}
} // namespace

NativeGeneratedFeatureFootprintCatalog compose_native_surface_forage_footprint(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements, const std::uint32_t ordinal,
    const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog) {
    const auto forage = NativeSurfaceForageOrderedDefinition::create(
        ordered, placements, ordinal, terrain, catalog);
    const double cell_size = terrain.pin().definition().constants().cell_size_meters;
    NativeGeneratedFeatureFootprintEntry entry;
    entry.feature_id = forage.placement().durable_id;
    entry.recipe_key = forage.recipe().recipe_id;
    entry.recipe_revision = 1U;
    entry.footprint_schema_revision = 1U;
    entry.generated_definition_digest = forage.content_digest();
    const auto visual = native_feature_runs_for_bounds(render_bounds(forage), cell_size,
        NativeFeatureFootprintChannel::render);
    entry.runs.insert(entry.runs.end(), visual.begin(), visual.end());
    const auto &anchor = forage.placement().world_anchor;
    const double x = anchor.x, y = anchor.y + forage.collider_center_y();
    const double z = anchor.z, radius = forage.collider_radius();
    const NativeFeatureWorldBounds physical{x-radius, y-radius, z-radius, x+radius, y+radius, z+radius};
    const auto collision = native_feature_runs_for_bounds(physical, cell_size,
        NativeFeatureFootprintChannel::collision);
    entry.runs.insert(entry.runs.end(), collision.begin(), collision.end());
    if (forage.navigation_blocker()) {
        const auto navigation = native_feature_runs_for_bounds(physical, cell_size,
            NativeFeatureFootprintChannel::navigation);
        entry.runs.insert(entry.runs.end(), navigation.begin(), navigation.end());
    }
    return NativeGeneratedFeatureFootprintCatalog::create(
        terrain.pin().physical_content_identity().digest, 1U, {std::move(entry)});
}

} // namespace voxel::world_backend
