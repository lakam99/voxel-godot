#include "../core/native_procedural_cave_field.hpp"
#include "../core/native_natural_terrain_source.hpp"
#include "test_harness.hpp"

#include "../core/biome_region_field.hpp"

#include <algorithm>
#include <cmath>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {
WorldSourceDefinition cave_definition(const std::string &seed) {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
    return WorldSourceDefinition(std::move(descriptor));
}

bool same_point(const CaveVector3 a, const CaveVector3 b) {
    return a.x == b.x && a.y == b.y && a.z == b.z;
}

bool same_recipe(const CaveRecipe &a, const CaveRecipe &b) {
    if (!(a.region == b.region) || !same_point(a.entry, b.entry)
        || a.route.size() != b.route.size() || a.loop.size() != b.loop.size()
        || a.deep_route.size() != b.deep_route.size() || a.segments.size() != b.segments.size()
        || a.chambers.size() != b.chambers.size()) return false;
    for (std::size_t index = 0; index < a.route.size(); ++index)
        if (!same_point(a.route[index], b.route[index])) return false;
    for (std::size_t index = 0; index < a.loop.size(); ++index)
        if (!same_point(a.loop[index], b.loop[index])) return false;
    for (std::size_t index = 0; index < a.deep_route.size(); ++index)
        if (!same_point(a.deep_route[index], b.deep_route[index])) return false;
    for (std::size_t index = 0; index < a.segments.size(); ++index) {
        if (!same_point(a.segments[index].a, b.segments[index].a)
            || !same_point(a.segments[index].b, b.segments[index].b)
            || a.segments[index].radius != b.segments[index].radius
            || a.segments[index].radius_end != b.segments[index].radius_end
            || a.segments[index].vertical_radius != b.segments[index].vertical_radius
            || a.segments[index].vertical_radius_end != b.segments[index].vertical_radius_end) return false;
    }
    for (std::size_t index = 0; index < a.chambers.size(); ++index) {
        if (!same_point(a.chambers[index].center, b.chambers[index].center)
            || !same_point(a.chambers[index].radii, b.chambers[index].radii)) return false;
    }
    return true;
}
} // namespace

VWB_TEST(native_procedural_cave_field_regions_match_script_floor_boundaries) {
    VWB_EXPECT((NativeProceduralCaveField::region_at({-96.0F, 0.0F, -96.0F}) == CaveRegionKey{0, 0}));
    VWB_EXPECT((NativeProceduralCaveField::region_at({-96.01F, 0.0F, -96.01F}) == CaveRegionKey{-1, -1}));
    VWB_EXPECT((NativeProceduralCaveField::region_at({96.0F, 0.0F, 96.0F}) == CaveRegionKey{1, 1}));
}

VWB_TEST(native_procedural_cave_field_recipes_are_repeatable_order_independent_and_protected) {
    const auto definition = cave_definition("cave-contract-417");
    NativeProceduralCaveField forward(definition);
    NativeProceduralCaveField reverse(definition);
    const NativeProceduralCaveField::SurfaceSampler surface = [](float, float) { return 60.0; };
    const NativeProceduralCaveField::ProtectedBounds unprotected = [](const CaveBounds &) { return false; };
    const NativeProceduralCaveField::ProtectedBounds protected_area = [](const CaveBounds &) { return true; };
    std::vector<std::pair<CaveRegionKey, std::optional<CaveRecipe>>> recipes;
    for (std::int32_t z = -8; z <= 8; ++z) {
        for (std::int32_t x = -8; x <= 8; ++x) {
            const CaveRegionKey region{x, z};
            const auto recipe = forward.recipe_for_region(region, surface, unprotected);
            if (recipe) {
                VWB_EXPECT(recipe->segments.size() >= 7U);
                VWB_EXPECT(recipe->chambers.size() == 3U);
                VWB_EXPECT(recipe->segments.front().radius == 2.5);
                VWB_EXPECT(recipe->segments.front().radius_end == 2.3);
                VWB_EXPECT(recipe->segments[1].radius == 2.3);
                VWB_EXPECT(recipe->segments[1].radius_end == 2.1);
                VWB_EXPECT(recipe->segments[1].vertical_radius == 1.2);
                VWB_EXPECT(recipe->segments[3].radius_end == 2.1);
                VWB_EXPECT(recipe->route.front().y < recipe->entry.y);
                VWB_EXPECT(std::abs((recipe->route.front().y - recipe->entry.y) + 0.3375F) < 0.001F);
                VWB_EXPECT((NativeProceduralCaveField::region_at(recipe->bounds.position) == region));
                VWB_EXPECT((NativeProceduralCaveField::region_at({
                    recipe->bounds.position.x + recipe->bounds.size.x,
                    recipe->bounds.position.y + recipe->bounds.size.y,
                    recipe->bounds.position.z + recipe->bounds.size.z}) == region));
            }
            recipes.emplace_back(region, recipe);
        }
    }
    VWB_EXPECT(std::any_of(recipes.begin(), recipes.end(), [](const auto &value) { return value.second.has_value(); }));
    for (auto iterator = recipes.rbegin(); iterator != recipes.rend(); ++iterator) {
        const auto reproduced = reverse.recipe_for_region(iterator->first, surface, unprotected);
        VWB_EXPECT(reproduced.has_value() == iterator->second.has_value());
        if (reproduced && iterator->second) VWB_EXPECT(same_recipe(*reproduced, *iterator->second));
    }
    const auto recipe_it = std::find_if(recipes.begin(), recipes.end(), [](const auto &value) {
        return value.second.has_value();
    });
    VWB_EXPECT(recipe_it != recipes.end());
    NativeProceduralCaveField rejected(definition);
    VWB_EXPECT(!rejected.recipe_for_region(recipe_it->first, surface, protected_area));
}

VWB_TEST(native_procedural_cave_field_density_clears_entrance_body_and_retains_floor) {
    NativeProceduralCaveField field(cave_definition("cave-contract-417"));
    const NativeProceduralCaveField::SurfaceSampler surface = [](float, float) { return 60.0; };
    const NativeProceduralCaveField::ProtectedBounds unprotected = [](const CaveBounds &) { return false; };
    std::optional<CaveRecipe> recipe;
    for (std::int32_t z = -8; z <= 8 && !recipe; ++z) {
        for (std::int32_t x = -8; x <= 8 && !recipe; ++x)
            recipe = field.recipe_for_region({x, z}, surface, unprotected);
    }
    VWB_EXPECT(recipe.has_value());
    const CaveVector3 body{recipe->entry.x, recipe->entry.y + 1.5F, recipe->entry.z};
    const CaveVector3 floor{recipe->route.front().x, recipe->route.front().y - 1.0F,
        recipe->route.front().z};
    VWB_EXPECT(field.recipe_density(body, *recipe) < 0.0);
    VWB_EXPECT(field.recipe_density(floor, *recipe) > 0.0);

    const CaveVector3 interior = recipe->route[3];
    VWB_EXPECT(field.recipe_density({interior.x, interior.y + 9.0F, interior.z}, *recipe) > 0.0);
}

VWB_TEST(native_procedural_cave_field_keeps_seeded_recipe_geometry_and_density_repeatable) {
    const auto definition = cave_definition("atlas-1492");
    const NativeNaturalTerrainSource natural(definition);
    NativeProceduralCaveField field(definition);
    const NativeProceduralCaveField::SurfaceSampler surface = [&natural](const float x, const float z) {
        constexpr double cell = 1.35;
        return natural.sample_surface_column({static_cast<std::int32_t>(std::floor(x / cell)),
            static_cast<std::int32_t>(std::floor(z / cell)), WorldQueryIntent::gameplay}).reference_surface_y;
    };
    const NativeProceduralCaveField::ProtectedBounds unprotected = [](const CaveBounds &) { return false; };
    const auto recipe = field.recipe_for_region({-1, -1}, surface, unprotected);
    VWB_EXPECT(recipe.has_value());
    VWB_EXPECT(recipe->route.size() == 7U);
    VWB_EXPECT(recipe->segments.size() >= recipe->route.size() - 1U);
    VWB_EXPECT(recipe->segments.front().radius == 2.5);
    VWB_EXPECT(recipe->segments[0].radius_end == 2.3);
    VWB_EXPECT(recipe->segments[1].radius_end == 2.1);
    VWB_EXPECT(recipe->segments[1].vertical_radius == 1.2);
    VWB_EXPECT(recipe->segments[3].radius_end == 2.1);
    VWB_EXPECT(recipe->route.front().y < recipe->entry.y);
    VWB_EXPECT(recipe->chambers.size() == 3U);
    // Frozen from the current visually verified atlas-1492 GDScript field,
    // region -1,-1. The prior region-0,0 oracle encoded an older straight
    // entrance and unbounded chamber profile and may now correctly reject.
    VWB_EXPECT(std::abs(recipe->entry.x + 211.376F) < 0.01F);
    VWB_EXPECT(std::abs(recipe->entry.y - 18.0466626F) < 0.01F);
    VWB_EXPECT(std::abs(recipe->entry.z + 153.9749F) < 0.01F);
    VWB_EXPECT(std::abs((recipe->route.front().y - recipe->entry.y) + 0.3375F) < 0.001F);
    VWB_EXPECT(std::abs(recipe->route.back().y - (recipe->entry.y - 7.5F)) < 0.001F);
    VWB_EXPECT(recipe->chambers[0].radii.y >= 2.7F);
    VWB_EXPECT(recipe->chambers[1].radii.y >= 2.5F);
    VWB_EXPECT(recipe->chambers[2].radii.y >= 2.5F);
    const double roof_reserve = definition.constants().cell_size_meters + 1.1 + 0.24;
    for (const CaveChamber &chamber : recipe->chambers) {
        VWB_EXPECT(surface(chamber.center.x, chamber.center.z)
            - chamber.center.y - chamber.radii.y >= roof_reserve - 0.001);
    }
    const CaveVector3 point{-21.0F * 1.35F, -1.0F * 1.35F, -4.0F * 1.35F};
    const double surface_y = surface(point.x, point.z);
    VWB_EXPECT_EQ(16.983000000000004, surface_y);
    const double first = field.density(point, surface_y - point.y, surface, unprotected);
    const double second = field.density(point, surface_y - point.y, surface, unprotected);
    VWB_EXPECT(std::isfinite(first));
    VWB_EXPECT_EQ(first, second);
}

VWB_TEST(native_procedural_cave_field_preserves_the_scripted_seeded_mouth) {
    const auto definition = cave_definition("cave-contract-417");
    const NativeNaturalTerrainSource natural(definition);
    NativeProceduralCaveField field(definition);
    const NativeProceduralCaveField::SurfaceSampler surface = [&natural](const float x, const float z) {
        constexpr double cell = 1.35;
        return natural.sample_surface_column({static_cast<std::int32_t>(std::floor(x / cell)),
            static_cast<std::int32_t>(std::floor(z / cell)), WorldQueryIntent::gameplay}).reference_surface_y;
    };
    const NativeProceduralCaveField::ProtectedBounds unprotected = [](const CaveBounds &) { return false; };
    const auto recipe = field.recipe_for_region({-2, 0}, surface, unprotected);
    VWB_EXPECT(recipe.has_value());
    if (!recipe) return;

    // Frozen from the GDScript contract runner's chosen cave-contract-417
    // region. This catches a native recipe that builds a different mouth or
    // silently disappears during native admission.
    VWB_EXPECT(std::abs(recipe->entry.x + 431.8339F) < 0.05F);
    VWB_EXPECT(std::abs(recipe->entry.y - 17.901F) < 0.05F);
    VWB_EXPECT(std::abs(recipe->entry.z + 15.55816F) < 0.05F);
    const double surface_y = surface(-432.0F, -16.2F);
    const double body_density = field.density({-432.0F, 16.2F, -16.2F},
        surface_y - 16.2, surface, unprotected);
    VWB_EXPECT(body_density < 0.0);
}
