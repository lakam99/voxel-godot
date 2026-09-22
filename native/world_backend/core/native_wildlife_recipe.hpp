#pragma once

#include "native_wildlife_presentation_receipt.hpp"

#include <cstdint>
#include <stdexcept>
#include <string>

namespace voxel::world_backend {

// The current navigation adapter indexes wildlife with the same static-prop
// blocker policy as trees and rocks.  It is intentionally not reclassified as
// a dynamic actor until that is an explicit gameplay change.
enum class NativeWildlifeNavigationPolicy : std::uint8_t {
    static_prop_blocker = 1,
};

// The adapter maps the native surface-biome identity into this deliberately
// small selection group.  The table is the current production profile rule;
// no renderer or asset readiness state participates in variant selection.
enum class NativeWildlifeBiomeGroup : std::uint8_t {
    cold = 1,
    forest_or_plains = 2,
    dry = 3,
    swamp = 4,
    other = 5,
};

struct NativeWildlifeBoxCollider final {
    float size_x = 0.0F;
    float size_y = 0.0F;
    float size_z = 0.0F;
    float center_y = 0.0F;
};

// Immutable variant data copied from the current source profile table.  Cold
// is deliberately not stored here: it belongs to the source-selected biome
// receipt and only scales the runtime movement speed.
struct NativeWildlifeRecipe final {
    std::uint32_t revision = 1U;
    NativeWildlifeVariant variant = NativeWildlifeVariant::boar;
    std::string material_id;
    std::string primary_drop_id;
    std::int32_t primary_drop_min = 0;
    std::int32_t primary_drop_max = 0;
    std::string extra_drop_id;
    std::int32_t extra_drop_min = 0;
    std::int32_t extra_drop_max = 0;
    float visual_scale = 0.0F;
    float speed_multiplier = 0.0F;
    float cold_speed_multiplier = 0.0F;
    NativeWildlifeBoxCollider collider;
    std::uint32_t collision_layer = 0U;
    std::uint32_t collision_mask = 0U;
    NativeWildlifeNavigationPolicy navigation = NativeWildlifeNavigationPolicy::static_prop_blocker;
};

class NativeWildlifeRecipeRejected final : public std::invalid_argument {
public:
    NativeWildlifeRecipeRejected();
};

class NativeWildlifeRecipeCatalog final {
public:
    static NativeWildlifeRecipe resolve(NativeWildlifeVariant variant);
};

class NativeWildlifeProfileSelector final {
public:
    static NativeWildlifeVariant select(NativeWildlifeBiomeGroup biome, float profile_roll);
};

} // namespace voxel::world_backend
