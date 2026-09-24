#pragma once

#include "native_conifer_recipe.hpp"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace voxel::world_backend {

// Pure source-space port of MathematicalTreePocSavannaRecipeBuilder v2.  The
// branch/foliage records intentionally reuse the already-frozen generic tree
// record layout used by the conifer port; no conifer morphology is reused.
using NativeSavannaVec3 = NativeConiferVec3;
using NativeSavannaBranch = NativeConiferBranch;
using NativeSavannaFoliage = NativeConiferFoliage;

struct NativeSavannaRecipe final {
    static constexpr int RECIPE_VERSION = 2;
    std::int64_t seed = 0;
    double maturity = 0.0, height = 0.0, trunk_radius = 0.0;
    double canopy_radius = 0.0, crown_base = 0.0, crown_height = 0.0;
    NativeSavannaVec3 crown_center, crown_radii;
    std::vector<NativeSavannaBranch> branches;
    std::vector<NativeSavannaFoliage> foliage;
    std::array<int, 5> segment_counts_by_order{};
    int node_count = 0, raised_fork_count = 0, crown_window_count = 0;
    int viable_axis_bud_count = 0, germinated_axis_count = 0, grown_metamer_count = 0;
    int pipe_junction_count = 0, occupied_crown_bins = 0;
    double girth_eligible_length = 0.0, girth_weighted_bud_charge = 0.0;
    double mean_lateral_scaffold_pitch = 0.0, maximum_major_wood_reach = 0.0;
    double pipe_max_relative_error = 0.0;
    std::string signature;
};

class NativeSavannaRecipeBuilder final {
public:
    static NativeSavannaRecipe build(std::int64_t seed, double maturity);
private:
    friend struct NativeSavannaRecipeTestAccess;
    static NativeSavannaRecipe build_with_limits(std::int64_t seed, double maturity,
        int segment_limit, int scaffold_limit, int foliage_limit);
    static NativeSavannaRecipe build_boundary_guard_fixture_for_test(std::int64_t seed);
};

} // namespace voxel::world_backend
