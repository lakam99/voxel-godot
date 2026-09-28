#include "test_harness.hpp"

#include "../core/native_wildlife_recipe.hpp"

#include <limits>

using namespace voxel::world_backend;

VWB_TEST(native_wildlife_recipe_catalog_resolves_current_physical_profiles) {
    const NativeWildlifeRecipe boar = NativeWildlifeRecipeCatalog::resolve(NativeWildlifeVariant::boar);
    VWB_EXPECT_EQ("wildlife", boar.material_id);
    VWB_EXPECT_EQ("rawMeat", boar.primary_drop_id);
    VWB_EXPECT_EQ(1, boar.primary_drop_min);
    VWB_EXPECT_EQ(3, boar.primary_drop_max);
    VWB_EXPECT_EQ("hide", boar.extra_drop_id);
    VWB_EXPECT_EQ(2, boar.extra_drop_max);
    VWB_EXPECT_EQ(0.72F, boar.visual_scale);
    VWB_EXPECT_EQ(0.92F, boar.speed_multiplier);
    VWB_EXPECT_EQ(0.86F, boar.cold_speed_multiplier);
    VWB_EXPECT_EQ(1.18F, boar.collider.size_x);
    VWB_EXPECT_EQ(1.05F, boar.collider.size_y);
    VWB_EXPECT_EQ(0.78F, boar.collider.size_z);
    VWB_EXPECT_EQ(0.52F, boar.collider.center_y);
    VWB_EXPECT_EQ(1U, boar.collision_layer);
    VWB_EXPECT_EQ(1U, boar.collision_mask);
    VWB_EXPECT_EQ(NativeWildlifeNavigationPolicy::static_prop_blocker, boar.navigation);

    const NativeWildlifeRecipe deer = NativeWildlifeRecipeCatalog::resolve(NativeWildlifeVariant::deer);
    VWB_EXPECT_EQ(3, deer.primary_drop_max);
    VWB_EXPECT_EQ(2, deer.extra_drop_max);
    VWB_EXPECT_EQ(0.66F, deer.visual_scale);
    VWB_EXPECT_EQ(1.10F, deer.speed_multiplier);
    VWB_EXPECT_EQ(0.94F, deer.collider.size_x);
    VWB_EXPECT_EQ(1.52F, deer.collider.size_y);
    VWB_EXPECT_EQ(0.72F, deer.collider.size_z);
    VWB_EXPECT_EQ(0.76F, deer.collider.center_y);

    const NativeWildlifeRecipe hare = NativeWildlifeRecipeCatalog::resolve(NativeWildlifeVariant::hare);
    VWB_EXPECT_EQ(1, hare.primary_drop_max);
    VWB_EXPECT_EQ(1, hare.extra_drop_max);
    VWB_EXPECT_EQ(0.92F, hare.visual_scale);
    VWB_EXPECT_EQ(1.34F, hare.speed_multiplier);
    VWB_EXPECT_EQ(0.62F, hare.collider.size_x);
    VWB_EXPECT_EQ(0.74F, hare.collider.size_y);
    VWB_EXPECT_EQ(0.52F, hare.collider.size_z);
    VWB_EXPECT_EQ(0.34F, hare.collider.center_y);
}

VWB_TEST(native_wildlife_recipe_catalog_rejects_unknown_variant) {
    VWB_EXPECT_THROW(NativeWildlifeRecipeRejected,
        NativeWildlifeRecipeCatalog::resolve(static_cast<NativeWildlifeVariant>(99)));
}

VWB_TEST(native_wildlife_profile_selector_preserves_each_biome_threshold) {
    VWB_EXPECT_EQ(NativeWildlifeVariant::hare,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::cold, 0.6199F));
    VWB_EXPECT_EQ(NativeWildlifeVariant::deer,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::cold, 0.62F));
    VWB_EXPECT_EQ(NativeWildlifeVariant::deer,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::forest_or_plains, 0.4199F));
    VWB_EXPECT_EQ(NativeWildlifeVariant::hare,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::forest_or_plains, 0.42F));
    VWB_EXPECT_EQ(NativeWildlifeVariant::boar,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::forest_or_plains, 0.68F));
    VWB_EXPECT_EQ(NativeWildlifeVariant::hare,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::dry, 0.6999F));
    VWB_EXPECT_EQ(NativeWildlifeVariant::boar,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::dry, 0.70F));
    VWB_EXPECT_EQ(NativeWildlifeVariant::boar,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::swamp, 0.6999F));
    VWB_EXPECT_EQ(NativeWildlifeVariant::hare,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::swamp, 0.70F));
    VWB_EXPECT_EQ(NativeWildlifeVariant::boar,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::other, 0.99F));
}

VWB_TEST(native_wildlife_profile_selector_rejects_invalid_group_or_roll) {
    VWB_EXPECT_THROW(NativeWildlifeRecipeRejected,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::cold, -0.01F));
    VWB_EXPECT_THROW(NativeWildlifeRecipeRejected,
        NativeWildlifeProfileSelector::select(NativeWildlifeBiomeGroup::cold, 1.0F));
    VWB_EXPECT_THROW(NativeWildlifeRecipeRejected,
        NativeWildlifeProfileSelector::select(
            NativeWildlifeBiomeGroup::cold, std::numeric_limits<float>::quiet_NaN()));
    VWB_EXPECT_THROW(NativeWildlifeRecipeRejected,
        NativeWildlifeProfileSelector::select(static_cast<NativeWildlifeBiomeGroup>(99), 0.5F));
}
