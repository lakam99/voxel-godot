#pragma once

#include "native_generated_feature_footprint_catalog.hpp"
#include "native_surface_ore_cluster_definition.hpp"

namespace voxel::world_backend {

class NativeSurfaceOreFootprintRejected final : public std::invalid_argument {
public:
    NativeSurfaceOreFootprintRejected();
};

struct NativeOreWorldBounds final {
    double min_x, min_y, min_z, max_x, max_y, max_z;
};

// Standalone bounded world-box quantizer. Analytic negative-coordinate and
// overflow cases can be checked without forging a private ordered stream.
std::vector<NativeFeatureFootprintRun> native_surface_ore_runs_for_bounds(
    NativeOreWorldBounds bounds, double cell_size,
    NativeFeatureFootprintChannel channel);

// Source-bound, child-ID-specific section footprint for a procedural ore
// cluster. Render bounds enclose the authored stone, seams and glints after
// arbitrary local rotations; collision/navigation use the one real sphere.
// Terrain source has no runs because removing an ore node edits no cells.
NativeGeneratedFeatureFootprintCatalog compose_native_surface_ore_footprints(
    const NativeSurfacePropSourceOrderedStream &ordered,
    const NativeSurfacePropOrderedPlacement &placements,
    std::uint32_t ordinal, const NativeEffectiveTerrainSource &terrain);

} // namespace voxel::world_backend
