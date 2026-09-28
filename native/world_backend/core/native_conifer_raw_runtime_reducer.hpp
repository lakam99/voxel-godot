#pragma once

#include "native_conifer_recipe.hpp"

#include <cstddef>
#include <string>
#include <vector>

namespace voxel::world_backend {

// Exact pure-data `TreeSpawnService.reduce_raw_runtime_recipe` boundary for
// conifer source graphs. Density is the direct-service value, not silently
// request-normalized. These are source-space anchors, not a publishable
// runtime recipe; adaptation, interaction facts and signatures occur later.
struct NativeConiferRawReduction final {
    std::size_t source_branch_count = 0, source_foliage_count = 0;
    int branch_budget = 0, foliage_budget = 0;
    std::vector<NativeConiferBranch> branches;
    std::vector<NativeConiferFoliage> foliage;
};

class NativeConiferRawRuntimeReducer final {
public:
    static NativeConiferRawReduction reduce(const NativeConiferRecipe &raw,
        double canopy_density, const std::string &lod_tier);
};

} // namespace voxel::world_backend
