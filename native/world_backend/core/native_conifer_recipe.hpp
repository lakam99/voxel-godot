#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace voxel::world_backend {

// Pure source-space port of MathematicalTreePocConiferRecipeBuilder v2.
// No render budget, runtime coordinate adaptation, or collision is inferred here.
struct NativeConiferVec3 final {
    float x = 0.0F, y = 0.0F, z = 0.0F;
};

struct NativeConiferBranch final {
    NativeConiferVec3 start, end;
    double radius_start = 0.0, radius_end = 0.0;
    int order = 0, parent_node = -1, child_node = -1;
    double stratum_bias = 0.0, wind_weight = 0.0;
};

struct NativeConiferFoliage final {
    NativeConiferVec3 position, rotation, scale;
    double wind_weight = 0.0, variation = 0.0, exposure = 0.0;
    int cluster_variant = 0, source_segment = -1, source_order = 0;
};

struct NativeConiferRecipe final {
    static constexpr int RECIPE_VERSION = 2;
    std::int64_t seed = 0;
    double maturity = 0.0, height = 0.0, trunk_radius = 0.0;
    double canopy_radius = 0.0, crown_base = 0.0, crown_height = 0.0;
    NativeConiferVec3 crown_center, crown_radii;
    std::vector<NativeConiferBranch> branches;
    std::vector<NativeConiferFoliage> foliage;
    std::array<int, 5> segment_counts_by_order{};
    int node_count = 0, whorl_count = 0, interstitial_spray_count = 0;
    int support_driven_branchlet_count = 0, pipe_junction_count = 0;
    double first_whorl_height = 0.0, mean_bough_bud_charge = 0.0;
    double lower_whorl_mean_length = 0.0, upper_whorl_mean_length = 0.0;
    double drooping_curtain_mean_pitch = 0.0, pipe_max_relative_error = 0.0;
    int occupied_crown_bins = 0;
    std::string signature;
};

class NativeConiferRecipeBuilder final {
public:
    static NativeConiferRecipe build(std::int64_t seed, double maturity);
    static std::uint32_t stable_hash(const std::string &text);
private:
    friend struct NativeConiferRecipeTestAccess;
    static NativeConiferRecipe build_with_limits(std::int64_t seed, double maturity,
        int segment_limit, int foliage_limit);
};

} // namespace voxel::world_backend
