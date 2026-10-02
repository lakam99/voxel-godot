#pragma once

#include "world_source.hpp"

#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

struct NativeDetailQuality final {
    double decorative_density = 0.74;
    std::int32_t decorative_detail_cap = 72;
};

// Owned copies of the current BiomeEnvironmentCatalog detail fields. This is
// policy input, not an alternate biome or terrain query.
struct NativeDetailPolicy final {
    double max_height_above_water = 1000000.0;
    std::vector<std::string> types;
    std::vector<float> thresholds;
    std::vector<float> y_offsets;
    std::vector<float> scale_mins;
    std::vector<float> scale_maxs;
};

// The source owner captures these facts from its admitted structure, volume,
// edited-height and catalog authorities. An ordinal and exact cell are checked
// against the advancing detail RNG; no Node, callback, RID or borrowed page is
// retained by this pure plan.
struct NativeDetailAttemptFacts final {
    std::uint32_t ordinal = 0U;
    std::int32_t cell_x = 0;
    std::int32_t cell_z = 0;
    bool blocked = false;
    bool surface_found = false;
    double surface_height = 0.0;
    std::string biome;
    bool has_variation_heights = false;
    std::array<double, 9> variation_heights{}; // dz=-1..1, dx=-1..1
    NativeDetailPolicy policy;
};

struct NativeDetailTransformIntent final {
    std::string detail_type;
    std::array<float, 3> origin{};
    double yaw = 0.0;
    float uniform_scale = 1.0F;
};

struct NativeDetailAttemptPlan final {
    std::uint32_t ordinal = 0U;
    std::int32_t cell_x = 0;
    std::int32_t cell_z = 0;
    std::uint64_t state_before_coordinates = 0U;
    std::uint64_t state_after_coordinates = 0U;
    std::uint64_t state_after_attempt = 0U;
    std::string choice_type;
    std::vector<NativeDetailTransformIntent> transforms;
};

class NativeDetailOrderedPlanRejected final : public std::invalid_argument {
public:
    NativeDetailOrderedPlanRejected();
};

class NativeDetailOrderedPlan final {
public:
    static constexpr std::int32_t CHUNK_CELLS = 28;
    static constexpr std::size_t MAX_ATTEMPTS = 256U;

    static NativeDetailOrderedPlan create(const AdmittedTerrainSeed &seed,
        std::int32_t chunk_x, std::int32_t chunk_z, NativeDetailQuality quality,
        std::vector<NativeDetailAttemptFacts> facts);

    std::uint32_t rng_seed() const noexcept;
    std::uint64_t final_rng_state() const noexcept;
    const std::vector<NativeDetailAttemptPlan> &attempts() const noexcept;

private:
    NativeDetailOrderedPlan(std::uint32_t seed, std::uint64_t final_state,
        std::vector<NativeDetailAttemptPlan> attempts) noexcept;

    std::uint32_t rng_seed_ = 0U;
    std::uint64_t final_rng_state_ = 0U;
    std::vector<NativeDetailAttemptPlan> attempts_;
};

} // namespace voxel::world_backend
