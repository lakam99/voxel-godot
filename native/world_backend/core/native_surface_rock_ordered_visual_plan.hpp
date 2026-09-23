#pragma once

#include "native_surface_rock_asset_catalog.hpp"
#include "native_surface_rock_ordered_composer.hpp"

namespace voxel::world_backend {

enum class NativeSurfaceRockVisualIntent : std::uint8_t {
    selected_asset = 1,
    primitive_required = 2,
};

class NativeSurfaceRockOrderedVisualPlanRejected final : public std::invalid_argument {
public:
    NativeSurfaceRockOrderedVisualPlanRejected();
};

// Shadow-only plan. It selects an asset from an immutable native catalog;
// actual Godot scene instantiation and primitive fallback remain publisher work.
// Adapter admission must separately prove the catalog snapshot came from the
// active VisualAssetRegistry manifest.
class NativeSurfaceRockOrderedVisualPlan final {
public:
    static NativeSurfaceRockOrderedVisualPlan create(
        const NativeSurfacePropSourceOrderedStream &ordered,
        const NativeSurfacePropOrderedPlacement &placements,
        std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain,
        const NativeSurfaceRockAssetCatalog &catalog);

    const NativeSurfaceRockDefinition &definition() const noexcept;
    const NativeSurfaceRockAssetSelection &selection() const noexcept;
    NativeSurfaceRockVisualIntent intent() const noexcept;

private:
    NativeSurfaceRockOrderedVisualPlan(NativeSurfaceRockDefinition definition,
        NativeSurfaceRockAssetSelection selection, NativeSurfaceRockVisualIntent intent) noexcept;
    NativeSurfaceRockDefinition definition_;
    NativeSurfaceRockAssetSelection selection_;
    NativeSurfaceRockVisualIntent intent_;
};

} // namespace voxel::world_backend
