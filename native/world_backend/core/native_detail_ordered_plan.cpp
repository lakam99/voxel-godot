#include "native_detail_ordered_plan.hpp"

#include "godot_pcg_compat.hpp"
#include "legacy_seed_hash.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace voxel::world_backend {
namespace {

constexpr double CELL = 1.35;
constexpr double WATER_LEVEL = 11.1;
constexpr double PI = 3.14159265358979323846;
constexpr double TAU = 6.28318530717958647692;

[[noreturn]] void reject() { throw NativeDetailOrderedPlanRejected(); }

bool finite(double value) noexcept { return std::isfinite(value); }

std::int32_t checked_cell(std::int32_t chunk, std::int32_t offset) {
    const std::int64_t value = static_cast<std::int64_t>(chunk) * NativeDetailOrderedPlan::CHUNK_CELLS + offset;
    if (value < std::numeric_limits<std::int32_t>::min()
        || value > std::numeric_limits<std::int32_t>::max()) reject();
    return static_cast<std::int32_t>(value);
}

std::uint32_t detail_seed(const AdmittedTerrainSeed &seed, std::int32_t chunk_x, std::int32_t chunk_z) {
    try {
        const AdmittedTerrainSeed admitted = validate_admitted_raw_terrain_seed(
            seed.code_points, seed.utf8, seed.admitted);
        std::vector<std::uint32_t> key = admitted.code_points;
        const std::string suffix = ":details:" + std::to_string(chunk_x) + "," + std::to_string(chunk_z);
        for (const unsigned char byte : suffix) key.push_back(byte);
        return legacy_seed_hash(key);
    } catch (const std::invalid_argument &) {
        reject();
    }
}

std::size_t attempt_count(NativeDetailQuality quality) {
    if (!finite(quality.decorative_density) || quality.decorative_detail_cap < 0
        || quality.decorative_detail_cap > 256) reject();
    const double density = std::clamp(quality.decorative_density, 0.0, 1.0);
    if (density <= 0.01) return 0U;
    const double rounded = std::floor(static_cast<double>(quality.decorative_detail_cap) * density + 0.5);
    const std::size_t result = static_cast<std::size_t>(std::max(8.0, rounded));
    if (result > NativeDetailOrderedPlan::MAX_ATTEMPTS) reject();
    return result;
}

void validate_policy(const NativeDetailPolicy &policy) {
    const std::size_t count = policy.types.size();
    if (count == 0U || count > 64U || policy.thresholds.size() != count
        || policy.y_offsets.size() != count || policy.scale_mins.size() != count
        || policy.scale_maxs.size() != count || !finite(policy.max_height_above_water)
        || policy.max_height_above_water < 0.0) reject();
    float previous = 0.0F;
    for (std::size_t i = 0; i < count; ++i) {
        if (!finite(policy.thresholds[i]) || policy.thresholds[i] <= previous
            || policy.thresholds[i] > 1.0F || !finite(policy.y_offsets[i])
            || !finite(policy.scale_mins[i]) || !finite(policy.scale_maxs[i])
            || policy.scale_mins[i] > policy.scale_maxs[i]) reject();
        previous = policy.thresholds[i];
    }
}

float randf_range(GodotPcg32 &rng, float from, float to) noexcept {
    return from + rng.randf() * (to - from);
}

std::array<float, 3> add(std::array<float, 3> a, std::array<float, 3> b) noexcept {
    return {a[0] + b[0], a[1] + b[1], a[2] + b[2]};
}

std::array<float, 3> subtract(std::array<float, 3> a, std::array<float, 3> b) noexcept {
    return {a[0] - b[0], a[1] - b[1], a[2] - b[2]};
}

} // namespace

NativeDetailOrderedPlanRejected::NativeDetailOrderedPlanRejected()
    : std::invalid_argument("invalid native detail ordered plan input") {}

NativeDetailOrderedPlan::NativeDetailOrderedPlan(const std::uint32_t seed,
    const std::uint64_t final_state, std::vector<NativeDetailAttemptPlan> attempts) noexcept
    : rng_seed_(seed), final_rng_state_(final_state), attempts_(std::move(attempts)) {}

NativeDetailOrderedPlan NativeDetailOrderedPlan::create(const AdmittedTerrainSeed &seed,
    const std::int32_t chunk_x, const std::int32_t chunk_z, const NativeDetailQuality quality,
    std::vector<NativeDetailAttemptFacts> facts) {
    const std::size_t count = attempt_count(quality);
    if (facts.size() != count) reject();
    const std::uint32_t seed_value = detail_seed(seed, chunk_x, chunk_z);
    GodotPcg32 rng(seed_value);
    std::vector<NativeDetailAttemptPlan> rows;
    rows.reserve(count);
    for (std::size_t i = 0; i < count; ++i) {
        const auto &source = facts[i];
        if (source.ordinal != i || !finite(source.surface_height)) reject();
        NativeDetailAttemptPlan row;
        row.ordinal = static_cast<std::uint32_t>(i);
        row.state_before_coordinates = rng.state();
        row.cell_x = checked_cell(chunk_x, 1 + static_cast<std::int32_t>(rng.randi_range(0, 26)));
        row.cell_z = checked_cell(chunk_z, 1 + static_cast<std::int32_t>(rng.randi_range(0, 26)));
        row.state_after_coordinates = rng.state();
        if (source.cell_x != row.cell_x || source.cell_z != row.cell_z) reject();
        const bool eligible = !source.blocked && source.surface_found
            && source.surface_height >= WATER_LEVEL - 0.1 && source.surface_height <= 104.0
            && source.biome != "town";
        if (eligible) {
            if (!source.has_variation_heights) reject();
            validate_policy(source.policy);
            double maximum_delta = 0.0;
            const double center = source.variation_heights[4];
            for (const double height : source.variation_heights) {
                if (!finite(height)) reject();
                maximum_delta = std::max(maximum_delta, std::abs(height - center));
            }
            if (maximum_delta <= CELL * 1.35) {
                const float jitter_x = randf_range(rng, -0.42F, 0.42F);
                const float jitter_z = randf_range(rng, -0.42F, 0.42F);
                const std::array<float, 3> local{
                    static_cast<float>(static_cast<double>(row.cell_x - checked_cell(chunk_x, 0))
                        * CELL + static_cast<double>(jitter_x)),
                    static_cast<float>(source.surface_height),
                    static_cast<float>(static_cast<double>(row.cell_z - checked_cell(chunk_z, 0))
                        * CELL + static_cast<double>(jitter_z))};
                const float roll = rng.randf();
                if (source.surface_height <= WATER_LEVEL + source.policy.max_height_above_water) {
                    std::size_t selected = source.policy.types.size();
                    for (std::size_t choice = 0; choice < source.policy.thresholds.size(); ++choice) {
                        if (roll < source.policy.thresholds[choice]) { selected = choice; break; }
                    }
                    if (selected < source.policy.types.size()) {
                        row.choice_type = source.policy.types[selected];
                        if (row.choice_type == "flower") {
                            const double yaw = static_cast<double>(rng.randf()) * TAU;
                            const float scale = randf_range(rng, 0.82F, 1.18F);
                            const double offset_yaw = yaw + PI * 0.5;
                            const std::array<float, 3> offset{
                                static_cast<float>(std::cos(offset_yaw)) * 0.08F, 0.0F,
                                static_cast<float>(std::sin(offset_yaw)) * 0.08F};
                            const auto raised = add(local, {0.0F, 0.15F, 0.0F});
                            row.transforms.push_back({"flowerStem", subtract(raised, offset), yaw, scale});
                            row.transforms.push_back({"flowerBloom", add(raised, offset), yaw + PI * 0.62, scale});
                        } else if (!row.choice_type.empty()) {
                            const double yaw = static_cast<double>(rng.randf()) * TAU;
                            const float scale = randf_range(rng, source.policy.scale_mins[selected],
                                source.policy.scale_maxs[selected]);
                            row.transforms.push_back({row.choice_type,
                                add(local, {0.0F, source.policy.y_offsets[selected], 0.0F}), yaw, scale});
                        }
                    }
                }
            }
        }
        row.state_after_attempt = rng.state();
        rows.push_back(std::move(row));
    }
    return NativeDetailOrderedPlan(seed_value, rng.state(), std::move(rows));
}

std::uint32_t NativeDetailOrderedPlan::rng_seed() const noexcept { return rng_seed_; }
std::uint64_t NativeDetailOrderedPlan::final_rng_state() const noexcept { return final_rng_state_; }
const std::vector<NativeDetailAttemptPlan> &NativeDetailOrderedPlan::attempts() const noexcept { return attempts_; }

} // namespace voxel::world_backend
