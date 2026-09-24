#include "test_harness.hpp"

#include "../core/native_savanna_recipe.hpp"
#include "../core/native_savanna_worker_recipe.hpp"

#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

struct Checkpoint final {
    std::size_t index = 0U;
    std::uint32_t hash = 0U;
};

struct RawObservation final {
    std::int64_t seed = 0;
    double maturity = 0.0;
    NativeSavannaRecipe recipe;
    std::uint32_t branch_selection_hash = 0U;
    std::uint32_t foliage_selection_hash = 0U;
    std::vector<Checkpoint> branch_checkpoints;
    std::vector<Checkpoint> foliage_checkpoints;
};

struct WorkerObservation final {
    int case_index = 0;
    NativeSavannaWorkerRecipe recipe;
    std::uint32_t branch_selection_hash = 0U;
    std::uint32_t foliage_selection_hash = 0U;
};

int rounded(const double value) {
    return static_cast<int>(std::round(value));
}

std::string branch_selection_text(const NativeSavannaRecipe &recipe) {
    std::ostringstream text;
    for (std::size_t index = 0U; index < recipe.branches.size(); ++index) {
        const auto &branch = recipe.branches[index];
        if (index != 0U) text << '|';
        text << branch.child_node << ':'
             << rounded(double(branch.start.x) * 1000.0) << ','
             << rounded(double(branch.start.y) * 1000.0) << ','
             << rounded(double(branch.start.z) * 1000.0) << ':'
             << rounded(double(branch.end.x) * 1000.0) << ','
             << rounded(double(branch.end.y) * 1000.0) << ','
             << rounded(double(branch.end.z) * 1000.0) << ':'
             << rounded(branch.radius_start * 1000.0) << ':'
             << rounded(branch.radius_end * 1000.0) << ':' << branch.order;
    }
    return text.str();
}

std::string foliage_selection_text(const NativeSavannaRecipe &recipe) {
    std::ostringstream text;
    for (std::size_t index = 0U; index < recipe.foliage.size(); ++index) {
        const auto &anchor = recipe.foliage[index];
        if (index != 0U) text << '|';
        text << anchor.source_segment << ':' << anchor.cluster_variant << ':'
             << rounded(double(anchor.position.x) * 1000.0) << ','
             << rounded(double(anchor.position.y) * 1000.0) << ','
             << rounded(double(anchor.position.z) * 1000.0) << ':' << anchor.source_order;
    }
    return text.str();
}

bool checkpoint_index(const std::size_t index, const std::size_t count) {
    return index < 5U || index % 25U == 24U || index + 1U == count;
}

RawObservation observe_raw(const std::int64_t seed, const double maturity) {
    RawObservation result;
    result.seed = seed;
    result.maturity = maturity;
    result.recipe = NativeSavannaRecipeBuilder::build(seed, maturity);
    result.branch_selection_hash = NativeConiferRecipeBuilder::stable_hash(branch_selection_text(result.recipe));
    result.foliage_selection_hash = NativeConiferRecipeBuilder::stable_hash(foliage_selection_text(result.recipe));
    std::ostringstream initial;
    initial << "math-tree-v2:" << seed << ':' << rounded(maturity * 100000.0) << ':'
            << rounded(result.recipe.height * 1000.0) << ':' << result.recipe.branches.size();
    std::uint32_t cumulative = NativeConiferRecipeBuilder::stable_hash(initial.str());
    for (std::size_t index = 0U; index < result.recipe.branches.size(); ++index) {
        const auto &branch = result.recipe.branches[index];
        std::ostringstream row;
        row << cumulative << ':'
            << rounded(double(branch.start.x) * 1000.0) << ','
            << rounded(double(branch.start.y) * 1000.0) << ','
            << rounded(double(branch.start.z) * 1000.0) << ':'
            << rounded(double(branch.end.x) * 1000.0) << ','
            << rounded(double(branch.end.y) * 1000.0) << ','
            << rounded(double(branch.end.z) * 1000.0) << ':'
            << rounded(branch.radius_start * 1000.0) << ':'
            << rounded(branch.radius_end * 1000.0) << ':' << branch.order;
        cumulative = NativeConiferRecipeBuilder::stable_hash(row.str());
        if (checkpoint_index(index, result.recipe.branches.size())) {
            result.branch_checkpoints.push_back({index, cumulative});
        }
    }
    for (std::size_t index = 0U; index < result.recipe.foliage.size(); ++index) {
        const auto &anchor = result.recipe.foliage[index];
        std::ostringstream row;
        row << cumulative << ':'
            << rounded(double(anchor.position.x) * 1000.0) << ','
            << rounded(double(anchor.position.y) * 1000.0) << ','
            << rounded(double(anchor.position.z) * 1000.0) << ':' << anchor.source_order;
        cumulative = NativeConiferRecipeBuilder::stable_hash(row.str());
        if (checkpoint_index(index, result.recipe.foliage.size())) {
            result.foliage_checkpoints.push_back({index, cumulative});
        }
    }
    return result;
}

NativeSavannaWorkerRequest base_worker_request() {
    NativeSavannaWorkerRequest request;
    request.tree_id = "oracle-tree"; request.world_seed = "oracle-world"; request.biome = "savanna";
    request.architecture = "savanna"; request.species_grammar = "umbrella_thorn";
    request.genetic_seed = 0x53415641; request.growth_stage = 0.92;
    request.visual_height = 26.0; request.trunk_radius = 1.1; request.canopy_radius = 8.0;
    request.has_trunk_radius = true; request.has_canopy_radius = true;
    request.canopy_density = 0.78; request.age_band = "mature"; request.age_years = 55.0;
    request.render_lod_tier = "near"; request.presentation = "runtime";
    request.world_position = {4.0F, 5.0F, 6.0F}; request.world_rotation_y = 0.5;
    auto &parameters = request.biome_parameters;
    parameters.version = 2; parameters.architecture = "savanna";
    parameters.height_min = 10.0; parameters.height_max = 30.0;
    parameters.trunk_radius_min = 0.5; parameters.trunk_radius_max = 3.0;
    parameters.canopy_radius_min = 7.0; parameters.canopy_radius_max = 24.0;
    parameters.canopy_density = 0.88; parameters.wind_response = 1.25;
    parameters.visibility_range = 350.0; parameters.shadow_range = 170.0;
    parameters.exclusion_margin = 0.4;
    return request;
}

std::uint32_t worker_branch_hash(const NativeSavannaWorkerRecipe &recipe) {
    std::ostringstream text;
    for (std::size_t index = 0U; index < recipe.branches.size(); ++index) {
        if (index != 0U) text << ',';
        text << recipe.branches[index].child_node;
    }
    return NativeConiferRecipeBuilder::stable_hash(text.str());
}

std::uint32_t worker_foliage_hash(const NativeSavannaWorkerRecipe &recipe) {
    std::ostringstream text;
    for (std::size_t index = 0U; index < recipe.foliage.size(); ++index) {
        if (index != 0U) text << ',';
        text << recipe.foliage[index].source_segment << ':' << recipe.foliage[index].cluster_variant;
    }
    return NativeConiferRecipeBuilder::stable_hash(text.str());
}

std::vector<WorkerObservation> observe_workers() {
    std::vector<NativeSavannaWorkerRequest> requests(7U, base_worker_request());
    requests[1].species_grammar.clear();
    requests[2].genetic_seed = -319; requests[2].growth_stage = 0.12;
    requests[2].canopy_density = 0.20; requests[2].render_lod_tier = "mid";
    requests[3].genetic_seed = -319; requests[3].growth_stage = 1.0;
    requests[3].canopy_density = 1.0; requests[3].render_lod_tier = "far";
    requests[4].presentation = "review";
    requests[5].render_lod_tier = "impostor";
    requests[6].presentation = "review"; requests[6].render_lod_tier = "impostor";
    std::vector<WorkerObservation> result;
    for (std::size_t index = 0U; index < requests.size(); ++index) {
        NativeSavannaWorkerRecipe recipe = NativeSavannaWorkerRecipeBuilder::build(requests[index]);
        const std::uint32_t branch_hash = worker_branch_hash(recipe);
        const std::uint32_t foliage_hash = worker_foliage_hash(recipe);
        result.push_back({static_cast<int>(index), std::move(recipe), branch_hash, foliage_hash});
    }
    return result;
}

bool rooted_graph(const std::vector<NativeSavannaBranch> &branches) {
    std::unordered_set<int> reachable{0};
    for (const NativeSavannaBranch &branch : branches) {
        if (branch.parent_node < 0 || branch.child_node <= 0 || branch.parent_node == branch.child_node) {
            return false;
        }
        if (reachable.find(branch.parent_node) == reachable.end()) return false;
        if (!reachable.insert(branch.child_node).second) return false;
    }
    return true;
}

bool observation_requested() {
#ifdef _WIN32
    char *value = nullptr;
    std::size_t size = 0U;
    (void)_dupenv_s(&value, &size, "VWB_NATIVE_SAVANNA_ORACLE");
    const bool present = value != nullptr;
    std::free(value);
    return present;
#else
    return std::getenv("VWB_NATIVE_SAVANNA_ORACLE") != nullptr;
#endif
}

void print_checkpoints(const std::vector<Checkpoint> &values) {
    std::cout << '[';
    for (std::size_t index = 0U; index < values.size(); ++index) {
        if (index != 0U) std::cout << ',';
        std::cout << '[' << values[index].index << ',' << values[index].hash << ']';
    }
    std::cout << ']';
}

void emit_raw(const RawObservation &row) {
    const auto &recipe = row.recipe;
    std::cout << std::setprecision(17) << "VWB_NATIVE_SAVANNA_ORACLE:{\"seed\":" << row.seed
              << ",\"maturity\":" << row.maturity << ",\"signature\":\"" << recipe.signature
              << "\",\"height\":" << recipe.height << ",\"trunkRadius\":" << recipe.trunk_radius
              << ",\"canopyRadius\":" << recipe.canopy_radius << ",\"crownBase\":" << recipe.crown_base
              << ",\"crownHeight\":" << recipe.crown_height << ",\"branchCount\":" << recipe.branches.size()
              << ",\"foliageCount\":" << recipe.foliage.size() << ",\"nodeCount\":" << recipe.node_count
              << ",\"segmentCountsByOrder\":[";
    for (std::size_t index = 0U; index < recipe.segment_counts_by_order.size(); ++index) {
        if (index != 0U) std::cout << ',';
        std::cout << recipe.segment_counts_by_order[index];
    }
    std::cout << "],\"raisedForkCount\":" << recipe.raised_fork_count
              << ",\"crownWindowCount\":" << recipe.crown_window_count
              << ",\"viableAxisBudCount\":" << recipe.viable_axis_bud_count
              << ",\"germinatedAxisCount\":" << recipe.germinated_axis_count
              << ",\"grownMetamerCount\":" << recipe.grown_metamer_count
              << ",\"pipeModelJunctionCount\":" << recipe.pipe_junction_count
              << ",\"occupiedCrownBins\":" << recipe.occupied_crown_bins
              << ",\"branchSelectionHash\":" << row.branch_selection_hash
              << ",\"foliageSelectionHash\":" << row.foliage_selection_hash
              << ",\"branchHashCheckpoints\":";
    print_checkpoints(row.branch_checkpoints);
    std::cout << ",\"foliageHashCheckpoints\":";
    print_checkpoints(row.foliage_checkpoints);
    std::cout << "}\n";
}

void emit_worker(const WorkerObservation &row) {
    const auto &recipe = row.recipe;
    std::cout << std::setprecision(17) << "VWB_NATIVE_SAVANNA_WORKER_ORACLE:{\"caseIndex\":" << row.case_index
              << ",\"signature\":\"" << recipe.signature << "\",\"topologySignature\":\""
              << recipe.topology_signature << "\",\"sourceBranches\":" << recipe.source_branch_count
              << ",\"sourceFoliage\":" << recipe.source_foliage_count
              << ",\"branches\":" << recipe.branches.size() << ",\"foliage\":" << recipe.foliage.size()
              << ",\"branchSelectionHash\":" << row.branch_selection_hash
              << ",\"foliageSelectionHash\":" << row.foliage_selection_hash
              << ",\"renderTier\":\"" << recipe.render_lod_tier << "\",\"branchBudget\":"
              << recipe.render_branch_budget << ",\"foliageBudget\":" << recipe.render_foliage_budget
              << ",\"visibilityRange\":" << recipe.render_visibility_range
              << ",\"shadowRange\":" << recipe.render_shadow_range
              << ",\"windResponse\":" << recipe.render_wind_response
              << ",\"review\":" << (recipe.review ? "true" : "false")
              << ",\"impostor\":" << (recipe.impostor ? "true" : "false")
              << ",\"collisionRadius\":" << recipe.collision_trunk_radius
              << ",\"collisionHeight\":" << recipe.collision_trunk_height
              << ",\"crownHabit\":\"" << recipe.crown_habit << "\",\"methodology\":\""
              << recipe.methodology << "\"}\n";
}

} // namespace

std::optional<int> emit_native_savanna_observations_if_requested() {
    if (!observation_requested()) return std::nullopt;
    for (const auto &[seed, maturity] : std::vector<std::pair<std::int64_t, double>>{
            {0x53415641, 0.92}, {-319, 0.12}, {320, 0.12}, {-319, 1.0}}) {
        emit_raw(observe_raw(seed, maturity));
    }
    for (const WorkerObservation &row : observe_workers()) emit_worker(row);
    return 0;
}

VWB_TEST(native_savanna_oracle_observation_covers_all_raw_checkpoints_and_worker_cases) {
    const RawObservation mature = observe_raw(0x53415641, 0.92);
    VWB_EXPECT_EQ(false, mature.branch_selection_hash == 0U);
    VWB_EXPECT_EQ(false, mature.foliage_selection_hash == 0U);
    VWB_EXPECT_EQ(false, mature.branch_checkpoints.empty());
    VWB_EXPECT_EQ(false, mature.foliage_checkpoints.empty());
    VWB_EXPECT_EQ(mature.recipe.branches.size() - 1U, mature.branch_checkpoints.back().index);
    VWB_EXPECT_EQ(mature.recipe.foliage.size() - 1U, mature.foliage_checkpoints.back().index);
    const std::vector<WorkerObservation> workers = observe_workers();
    VWB_EXPECT_EQ(std::size_t(7U), workers.size());
    VWB_EXPECT_EQ(std::string("tree-v10-7711f274"), workers.front().recipe.signature);
    VWB_EXPECT_EQ(std::string("tree-v10-cc6cb734"), workers.back().recipe.signature);
    for (const WorkerObservation &worker : workers) {
        VWB_EXPECT_EQ(true, rooted_graph(worker.recipe.branches));
        for (const NativeSavannaFoliage &anchor : worker.recipe.foliage) {
            VWB_EXPECT_EQ(true, anchor.source_segment >= 0);
        }
    }
    auto invalid = workers.front().recipe.branches;
    invalid.front().parent_node = -1;
    VWB_EXPECT_EQ(false, rooted_graph(invalid));
    invalid = workers.front().recipe.branches; invalid.front().child_node = 0;
    VWB_EXPECT_EQ(false, rooted_graph(invalid));
    invalid = workers.front().recipe.branches; invalid[1].child_node = invalid[1].parent_node;
    VWB_EXPECT_EQ(false, rooted_graph(invalid));
    invalid = workers.front().recipe.branches; invalid.front().parent_node = 999999;
    VWB_EXPECT_EQ(false, rooted_graph(invalid));
    invalid = workers.front().recipe.branches; invalid[2].child_node = invalid.front().child_node;
    VWB_EXPECT_EQ(false, rooted_graph(invalid));
}
