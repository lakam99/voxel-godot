#pragma once

#include "native_feature_footprint_geometry.hpp"
#include "native_surface_forage_ordered_definition.hpp"

namespace voxel::world_backend {

// One source-bound forage family entry. The physical sphere always has a
// collision footprint; the recipe independently decides navigation blocking.
NativeGeneratedFeatureFootprintCatalog compose_native_surface_forage_footprint(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements,
    std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog);

} // namespace voxel::world_backend
