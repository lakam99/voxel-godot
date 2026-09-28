#pragma once

#include "godot_pcg_compat.hpp"
#include "native_wildlife_recipe.hpp"

#include <cstdint>
#include <stdexcept>

namespace voxel::world_backend {

// Biome grouping and presentation capability are both source receipts.  This
// stream proves their shared-PCG effects; it does not inspect Godot nodes,
// inventory, physics, tombstones, or asset registries.
struct NativeWildlifeStreamInput final {
    NativeWildlifeBiomeGroup biome = NativeWildlifeBiomeGroup::other;
    NativeWildlifePresentationReceipt presentation;
};

struct NativeWildlifeStream final {
    NativeWildlifeRecipe recipe;
    NativeWildlifePresentationReceipt presentation;
    bool cold = false;
    std::uint64_t state_before = 0U;
    std::uint64_t state_after = 0U;
    float profile_roll = 0.0F;
    float yaw_roll = 0.0F;
    std::int64_t primary_drop_count = 0;
    std::int64_t extra_drop_count = 0;
    // Both presentation paths reserve exactly two operations: procedural
    // radius/height or animated scale/animation-speed.
    float presentation_first_roll = 0.0F;
    float presentation_second_roll = 0.0F;
    float direction_roll = 0.0F;
    float timer_roll = 0.0F;
    float speed_roll = 0.0F;
};

class NativeWildlifeStreamRejected final : public std::invalid_argument {
public:
    NativeWildlifeStreamRejected();
};

class NativeWildlifeStreamBuilder final {
public:
    static NativeWildlifeStream create(const NativeWildlifeStreamInput &input, GodotPcg32 &rng);
    static NativeWildlifeStream create(
        NativeWildlifeBiomeGroup biome, const NativeWildlifePresentationCatalog &catalog, GodotPcg32 &rng);
};

} // namespace voxel::world_backend
