#include "native_surface_rock_footprint.hpp"

#include <algorithm>
#include <cmath>

namespace voxel::world_backend {
namespace {
[[noreturn]] void reject() { throw NativeSurfaceRockFootprintRejected(); }

bool nonzero(const Sha256Digest &digest) {
    return std::any_of(digest.begin(), digest.end(), [](std::uint8_t byte) { return byte != 0U; });
}

bool finite_ordered(const NativeFeatureWorldBounds &b) {
    return std::isfinite(b.min_x) && std::isfinite(b.min_y) && std::isfinite(b.min_z)
        && std::isfinite(b.max_x) && std::isfinite(b.max_y) && std::isfinite(b.max_z)
        && b.min_x <= b.max_x && b.min_y <= b.max_y && b.min_z <= b.max_z;
}

NativeFeatureWorldBounds visual_bounds(const NativeSurfaceRockDefinitionInput &input,
    const NativeSurfaceRockAssetSelection &selected,
    const NativeSurfaceRockPublishedVisual outcome,
    const NativeSurfaceRockImportedBoundsReceipt *receipt) {
    const double x = input.position.x, y = input.position.y, z = input.position.z;
    NativeFeatureWorldBounds bounds{x, y, z, x, y, z};
    if (outcome == NativeSurfaceRockPublishedVisual::selected_import) {
        if (receipt == nullptr
            || receipt->asset_catalog_digest != selected.asset_catalog_digest
            || receipt->asset_id != selected.asset_id || receipt->asset_path != selected.asset_path
            || !nonzero(receipt->glb_digest) || !finite_ordered(receipt->imported_mesh_bounds)) reject();
        const auto &b = receipt->imported_mesh_bounds;
        // Mirrors add_generated_rock_visual's Y/Z-swapped Blender size policy.
        const double sx = input.visual_radius * 2.0 * input.visual_scale_x
            / std::max(0.1, static_cast<double>(selected.asset_size.x)) * selected.rock_scale;
        const double sy = input.visual_radius * input.visual_height_factor * input.visual_scale_y
            / std::max(0.1, static_cast<double>(selected.asset_size.z)) * selected.rock_scale;
        const double sz = input.visual_radius * 2.0 * input.visual_scale_z
            / std::max(0.1, static_cast<double>(selected.asset_size.y)) * selected.rock_scale;
        bounds = {x + b.min_x*sx, y + b.min_y*sy, z + b.min_z*sz,
            x + b.max_x*sx, y + b.max_y*sy, z + b.max_z*sz};
    } else if (outcome == NativeSurfaceRockPublishedVisual::primitive_fallback) {
        if (receipt != nullptr) reject();
        const double r = input.visual_radius, h = r * input.visual_height_factor * 0.5;
        const double hx = r * input.visual_scale_x, hy = h * input.visual_scale_y;
        const double hz = r * input.visual_scale_z, center_y = r * 0.42;
        bounds = {x-hx, y+center_y-hy, z-hz, x+hx, y+center_y+hy, z+hz};
    } else reject();
    if (!finite_ordered(bounds)) reject();
    native_feature_bounds_enclose_body_yaw(bounds, x, z);
    // Godot's imported ArrayMesh AABB can round a vertex by one float32 ULP,
    // and the runtime scale crosses additional float32 boundaries. Expand
    // before quantizing so boundary cells cannot be lost to those roundings.
    constexpr double FLOAT32_MARGIN_METERS = 0.0001;
    bounds.min_x -= FLOAT32_MARGIN_METERS; bounds.min_y -= FLOAT32_MARGIN_METERS;
    bounds.min_z -= FLOAT32_MARGIN_METERS; bounds.max_x += FLOAT32_MARGIN_METERS;
    bounds.max_y += FLOAT32_MARGIN_METERS; bounds.max_z += FLOAT32_MARGIN_METERS;
    return bounds;
}
} // namespace

NativeSurfaceRockFootprintRejected::NativeSurfaceRockFootprintRejected()
    : std::invalid_argument("invalid native source-bound rock footprint") {}

std::vector<NativeFeatureFootprintRun> native_surface_rock_geometry_runs(
    const NativeSurfaceRockDefinitionInput &input,
    const NativeSurfaceRockAssetSelection &selected,
    const NativeSurfaceRockPublishedVisual published_visual,
    const NativeSurfaceRockImportedBoundsReceipt *imported_bounds,
    const double cell_size) {
    try {
        auto runs = native_feature_runs_for_bounds(
            visual_bounds(input, selected, published_visual, imported_bounds), cell_size,
            NativeFeatureFootprintChannel::render);
        const double x = input.position.x, y = input.position.y + input.collision.center_y;
        const double z = input.position.z, r = input.collision.radius;
        const NativeFeatureWorldBounds physical{x-r,y-r,z-r,x+r,y+r,z+r};
        for (const auto channel : {NativeFeatureFootprintChannel::collision,
                NativeFeatureFootprintChannel::navigation}) {
            const auto cells = native_feature_runs_for_bounds(physical, cell_size, channel);
            runs.insert(runs.end(), cells.begin(), cells.end());
        }
        return runs;
    } catch (const std::invalid_argument &) { reject(); }
}

NativeGeneratedFeatureFootprintCatalog compose_native_surface_rock_footprint(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements, const std::uint32_t ordinal,
    const NativeEffectiveTerrainSource &terrain, const NativeSurfaceRockAssetCatalog &catalog,
    const NativeSurfaceRockPublishedVisual published_visual,
    const NativeSurfaceRockImportedBoundsReceipt *imported_bounds) {
    try {
        const auto plan = NativeSurfaceRockOrderedVisualPlan::create(
            ordered, placements, ordinal, terrain, catalog);
        if (published_visual == NativeSurfaceRockPublishedVisual::selected_import
            && plan.intent() != NativeSurfaceRockVisualIntent::selected_asset) reject();
        const double cell_size = terrain.pin().definition().constants().cell_size_meters;
        NativeGeneratedFeatureFootprintEntry entry;
        entry.feature_id = plan.definition().input().durable_feature_id;
        entry.recipe_key = "surface_rock";
        entry.recipe_revision = NativeSurfaceRockOrderedComposer::PRODUCER_REVISION;
        entry.footprint_schema_revision = 1U;
        std::vector<std::uint8_t> identity(plan.definition().content_digest().begin(),
            plan.definition().content_digest().end());
        identity.push_back(static_cast<std::uint8_t>(published_visual));
        if (imported_bounds != nullptr)
            identity.insert(identity.end(), imported_bounds->glb_digest.begin(), imported_bounds->glb_digest.end());
        entry.generated_definition_digest = sha256(identity);
        entry.runs = native_surface_rock_geometry_runs(plan.definition().input(), plan.selection(),
            published_visual, imported_bounds, cell_size);
        return NativeGeneratedFeatureFootprintCatalog::create(
            terrain.pin().physical_content_identity().digest, 1U, {std::move(entry)});
    } catch (const std::invalid_argument &) { reject(); }
}

} // namespace voxel::world_backend
