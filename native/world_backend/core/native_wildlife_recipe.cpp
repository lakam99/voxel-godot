#include "native_wildlife_recipe.hpp"

namespace voxel::world_backend {
namespace {

NativeWildlifeRecipe recipe(
    const NativeWildlifeVariant variant, const float scale, const float speed,
    const std::int32_t primary_max, const std::int32_t extra_max,
    const NativeWildlifeBoxCollider collider) {
    NativeWildlifeRecipe result;
    result.variant = variant;
    result.material_id = "wildlife";
    result.primary_drop_id = "rawMeat";
    result.primary_drop_min = 1;
    result.primary_drop_max = primary_max;
    result.extra_drop_id = "hide";
    result.extra_drop_min = 1;
    result.extra_drop_max = extra_max;
    result.visual_scale = scale;
    result.speed_multiplier = speed;
    result.cold_speed_multiplier = 0.86F;
    result.collider = collider;
    result.collision_layer = 1U;
    result.collision_mask = 1U;
    return result;
}

} // namespace

NativeWildlifeRecipeRejected::NativeWildlifeRecipeRejected()
    : std::invalid_argument("invalid native wildlife variant") {}

NativeWildlifeRecipe NativeWildlifeRecipeCatalog::resolve(const NativeWildlifeVariant variant) {
    switch (variant) {
    case NativeWildlifeVariant::boar:
        return recipe(variant, 0.72F, 0.92F, 3, 2, {1.18F, 1.05F, 0.78F, 0.52F});
    case NativeWildlifeVariant::deer:
        return recipe(variant, 0.66F, 1.10F, 3, 2, {0.94F, 1.52F, 0.72F, 0.76F});
    case NativeWildlifeVariant::hare:
        return recipe(variant, 0.92F, 1.34F, 1, 1, {0.62F, 0.74F, 0.52F, 0.34F});
    }
    throw NativeWildlifeRecipeRejected();
}

} // namespace voxel::world_backend
