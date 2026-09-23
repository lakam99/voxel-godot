#pragma once

#include "native_feature_footprint_geometry.hpp"
#include "native_surface_ore_cluster_definition.hpp"

namespace voxel::world_backend {

// Source-bound, child-ID-specific section footprint for a procedural ore
// cluster. Render bounds enclose the authored stone, seams and glints after
// arbitrary local rotations; collision/navigation use the one real sphere.
// Terrain source has no runs because removing an ore node edits no cells.
NativeGeneratedFeatureFootprintCatalog compose_native_surface_ore_footprints(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements,
    std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain);

} // namespace voxel::world_backend
