#pragma once

#include "native_feature_footprint_geometry.hpp"
#include "native_surface_ore_cluster_definition.hpp"

namespace voxel::world_backend {

// Geometry-only helper for one already decoded child. A caller must bind the
// complete source/owner identity before these runs can enter a transaction.
std::vector<NativeFeatureFootprintRun> native_surface_ore_child_footprint_runs(
    const NativeSurfaceOreChildDefinition &child, double cell_size);

// Source-bound, child-ID-specific section footprint for a procedural ore
// cluster. Render bounds enclose the authored stone, seams and glints after
// arbitrary local rotations; collision/navigation use the one real sphere.
// Terrain source has no runs because removing an ore node edits no cells.
NativeGeneratedFeatureFootprintCatalog compose_native_surface_ore_footprints(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements,
    std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain);

} // namespace voxel::world_backend
