#include "test_harness.hpp"
#include "../core/native_conifer_raw_runtime_reducer.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>

using namespace voxel::world_backend;

namespace {
struct Case final {
    std::int64_t seed; double maturity,density; const char *tier;
    int branch_budget,foliage_budget,source_branches,source_foliage,branches,foliage;
    std::uint32_t branch_hash,foliage_hash;
};

std::uint32_t branch_hash(const NativeConiferRawReduction &r) {
    std::string text;
    for (const auto &branch:r.branches) {
        if (!text.empty()) text.push_back(',');
        text+=std::to_string(branch.child_node);
    }
    return NativeConiferRecipeBuilder::stable_hash(text);
}
std::uint32_t foliage_hash(const NativeConiferRawReduction &r) {
    std::string text;
    for (const auto &anchor:r.foliage) {
        if (!text.empty()) text.push_back(',');
        text+=std::to_string(anchor.source_segment)+":"+std::to_string(anchor.cluster_variant);
    }
    return NativeConiferRecipeBuilder::stable_hash(text);
}
}

VWB_TEST(native_conifer_raw_reduction_matches_independent_godot_service_oracles) {
    // Direct `TreeSpawnService.reduce_raw_runtime_recipe` outputs; not derived
    // from the C++ port. Selection hashes cover every selected ordered anchor.
    constexpr std::array<Case,8> cases{{
        {0x4D415448,0.92,0.78,"near",392,579,640,850,390,579,687266255U,1325597174U},
        {0x4D415448,0.92,0.20,"mid",166,245,640,850,166,245,1436168690U,3077996887U},
        {0x4D415448,0.92,1.00,"far",97,143,640,850,97,143,3324234245U,2682614295U},
        {-319,0.12,0.65,"near",376,555,222,264,222,264,2801612488U,4010358221U},
        {-319,1.00,0.90,"mid",212,313,696,930,212,313,2012231088U,2307030233U},
        {-319,0.12,-0.25,"near",263,388,222,264,222,264,2801612488U,4010358221U},
        {0x4D415448,0.92,0.10,"mid",159,235,640,850,159,235,3639116856U,1380824673U},
        {0x4D415448,0.92,2.00,"far",126,185,640,850,126,185,3623652149U,1233830267U}
    }};
    for (const auto &c:cases) {
        const auto raw=NativeConiferRecipeBuilder::build(c.seed,c.maturity);
        const auto r=NativeConiferRawRuntimeReducer::reduce(raw,c.density,c.tier);
        VWB_EXPECT_EQ(c.branch_budget,r.branch_budget);
        VWB_EXPECT_EQ(c.foliage_budget,r.foliage_budget);
        VWB_EXPECT_EQ(static_cast<std::size_t>(c.source_branches),r.source_branch_count);
        VWB_EXPECT_EQ(static_cast<std::size_t>(c.source_foliage),r.source_foliage_count);
        VWB_EXPECT_EQ(static_cast<std::size_t>(c.branches),r.branches.size());
        VWB_EXPECT_EQ(static_cast<std::size_t>(c.foliage),r.foliage.size());
        VWB_EXPECT_EQ(c.branch_hash,branch_hash(r));
        VWB_EXPECT_EQ(c.foliage_hash,foliage_hash(r));
    }
}

VWB_TEST(native_conifer_raw_reduction_preserves_direct_density_and_normalizes_ascii_tier) {
    const auto raw=NativeConiferRecipeBuilder::build(-319,0.12);
    const auto near=NativeConiferRawRuntimeReducer::reduce(raw,0.20,"near");
    const auto low=NativeConiferRawRuntimeReducer::reduce(raw,-4.0," near ");
    const auto high=NativeConiferRawRuntimeReducer::reduce(raw,4.0,"UNKNOWN");
    const auto reference_high=NativeConiferRawRuntimeReducer::reduce(raw,1.0,"near");
    VWB_EXPECT_EQ(24,low.branch_budget);
    VWB_EXPECT_EQ(32,low.foliage_budget);
    VWB_EXPECT(near.branch_budget>low.branch_budget);
    VWB_EXPECT_EQ(reference_high.branch_budget,high.branch_budget);
    VWB_EXPECT_EQ(reference_high.foliage_budget,high.foliage_budget);
    VWB_EXPECT_EQ(reference_high.branch_budget,NativeConiferRawRuntimeReducer::reduce(raw,1.0,"").branch_budget);
    VWB_EXPECT_EQ(reference_high.branch_budget,NativeConiferRawRuntimeReducer::reduce(raw,1.0,"  ").branch_budget);
    VWB_EXPECT_EQ(reference_high.branch_budget,NativeConiferRawRuntimeReducer::reduce(raw,1.0," NEAR ").branch_budget);
    VWB_EXPECT_EQ(24,NativeConiferRawRuntimeReducer::reduce(raw,1.0,"impostor").branch_budget);
    VWB_EXPECT_THROW(std::invalid_argument, NativeConiferRawRuntimeReducer::reduce(raw,std::numeric_limits<double>::quiet_NaN(),"near"));
    VWB_EXPECT_THROW(std::invalid_argument, NativeConiferRawRuntimeReducer::reduce(raw,1e30,"near"));
    VWB_EXPECT_THROW(std::invalid_argument, NativeConiferRawRuntimeReducer::reduce(raw,-1e30,"near"));
    VWB_EXPECT_THROW(std::invalid_argument, NativeConiferRawRuntimeReducer::reduce(raw,std::numeric_limits<double>::max(),"near"));
    VWB_EXPECT_THROW(std::invalid_argument, NativeConiferRawRuntimeReducer::reduce(raw,0.5,"n\xC3\xA9" "ar"));
}

VWB_TEST(native_conifer_raw_reduction_handles_synthetic_graph_and_anchor_boundaries) {
    // Synthetic contract inputs exercise the shared reducer's defensive
    // topology/anchor paths. They are not claims about live conifer generation.
    NativeConiferRecipe raw;
    raw.branches.resize(100);
    for (int i=0;i<100;++i) {
        raw.branches[static_cast<std::size_t>(i)].child_node=i+1;
        raw.branches[static_cast<std::size_t>(i)].parent_node=i;
        raw.branches[static_cast<std::size_t>(i)].order=1;
    }
    raw.branches.front().parent_node=100; // A synthetic ancestry cycle.
    raw.branches.front().order=0;
    raw.branches[1].child_node=-1; // Defensive missing-child path.
    raw.branches[1].order=0;
    auto reduced=NativeConiferRawRuntimeReducer::reduce(raw,0.2,"far");
    VWB_EXPECT(reduced.branches.size()>=2);
    raw.branches[1].child_node=2; // Restore the cycle for visited detection.
    reduced=NativeConiferRawRuntimeReducer::reduce(raw,0.2,"far");
    VWB_EXPECT(reduced.branches.size()>=2);

    raw.branches.clear();
    raw.foliage.resize(40);
    for (auto &f:raw.foliage) f.source_segment=-1;
    reduced=NativeConiferRawRuntimeReducer::reduce(raw,0.2,"impostor");
    VWB_EXPECT_EQ(std::size_t(32),reduced.foliage.size());

    for (auto &f:raw.foliage) f.source_segment=7;
    reduced=NativeConiferRawRuntimeReducer::reduce(raw,0.2,"impostor");
    VWB_EXPECT_EQ(std::size_t(32),reduced.foliage.size());

    for (int i=0;i<40;++i) raw.foliage[static_cast<std::size_t>(i)].source_segment=i;
    reduced=NativeConiferRawRuntimeReducer::reduce(raw,0.2,"impostor");
    VWB_EXPECT_EQ(std::size_t(32),reduced.foliage.size());

    for (int i=0;i<40;++i) raw.foliage[static_cast<std::size_t>(i)].source_segment=i%32;
    reduced=NativeConiferRawRuntimeReducer::reduce(raw,0.2,"impostor");
    VWB_EXPECT_EQ(std::size_t(32),reduced.foliage.size());

    for (int i=0;i<40;++i) raw.foliage[static_cast<std::size_t>(i)].source_segment=i%20;
    reduced=NativeConiferRawRuntimeReducer::reduce(raw,0.2,"impostor");
    VWB_EXPECT_EQ(std::size_t(32),reduced.foliage.size());
}
