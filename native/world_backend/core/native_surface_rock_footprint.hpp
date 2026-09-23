#pragma once

#include "native_feature_footprint_geometry.hpp"
#include "native_surface_rock_ordered_visual_plan.hpp"

namespace voxel::world_backend {

enum class NativeSurfaceRockPublishedVisual : std::uint8_t {
    selected_import = 1,
    primitive_fallback = 2,
};

// Adapter admission must verify GLB SHA-256 against the selected file and
// imported bounds against Godot. A nominal manifest size is insufficient.
struct NativeSurfaceRockImportedBoundsReceipt final {
    Sha256Digest asset_catalog_digest{};
    Sha256Digest glb_digest{};
    std::string asset_id, asset_path;
    NativeFeatureWorldBounds imported_mesh_bounds{};
};

class NativeSurfaceRockFootprintRejected final : public std::invalid_argument {
public:
    NativeSurfaceRockFootprintRejected();
};

// Pure-core footprint of one source-ordered rock. Publication outcome is
// explicit because a selected GLB may fail to instantiate and use the same
// primitive fallback as an empty selection.
NativeGeneratedFeatureFootprintCatalog compose_native_surface_rock_footprint(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements, std::uint32_t ordinal,
    const NativeEffectiveTerrainSource &terrain,
    const NativeSurfaceRockAssetCatalog &catalog,
    NativeSurfaceRockPublishedVisual published_visual,
    const NativeSurfaceRockImportedBoundsReceipt *imported_bounds);

} // namespace voxel::world_backend
