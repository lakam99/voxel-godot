#pragma once

#include "native_feature_footprint_geometry.hpp"
#include "native_surface_forage_ordered_definition.hpp"

namespace voxel::world_backend {

// The same pure geometry-to-cell projection used by the source-bound catalog.
// This boundary permits direct Godot constructor AABBs to be checked against
// native runs without fabricating a world-generation placement witness.
std::vector<NativeFeatureFootprintRun> native_surface_forage_geometry_runs(
    const NativeForageDecodedGeometry &geometry, NativeForageVec3 world_anchor,
    double cell_size);

// One source-bound forage family entry. The physical sphere always has a
// collision footprint; the recipe independently decides navigation blocking.
NativeGeneratedFeatureFootprintCatalog compose_native_surface_forage_footprint(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements,
    std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog);

} // namespace voxel::world_backend
