#include "../core/native_procedural_cave_field.hpp"
#include "../core/native_natural_terrain_source.hpp"
#include "test_harness.hpp"

#include "../core/biome_region_field.hpp"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
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
        || a.depth_loops.size() != b.depth_loops.size()
        || a.depth_tier_links.size() != b.depth_tier_links.size()
        || a.chambers.size() != b.chambers.size()) return false;
    for (std::size_t index = 0; index < a.route.size(); ++index)
        if (!same_point(a.route[index], b.route[index])) return false;
    for (std::size_t index = 0; index < a.loop.size(); ++index)
        if (!same_point(a.loop[index], b.loop[index])) return false;
    for (std::size_t index = 0; index < a.deep_route.size(); ++index)
        if (!same_point(a.deep_route[index], b.deep_route[index])) return false;
    for (std::size_t index = 0; index < a.depth_loops.size(); ++index) {
        if (a.depth_loops[index].size() != b.depth_loops[index].size()) return false;
        for (std::size_t point = 0; point < a.depth_loops[index].size(); ++point)
            if (!same_point(a.depth_loops[index][point], b.depth_loops[index][point])) return false;
    }
    for (std::size_t index = 0; index < a.depth_tier_links.size(); ++index) {
        const auto &left = a.depth_tier_links[index];
        const auto &right = b.depth_tier_links[index];
        if (left.id != right.id || left.from_tier != right.from_tier
            || left.to_tier != right.to_tier || left.points.size() != right.points.size()) return false;
        for (std::size_t point = 0; point < left.points.size(); ++point)
            if (!same_point(left.points[point], right.points[point])) return false;
    }
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

bool footprint_intersects_recipe_bounds_reference(NativeProceduralCaveField &field,
    const CaveVector3 position, const double radius,
    const NativeProceduralCaveField::SurfaceSampler &surface,
    const NativeProceduralCaveField::ProtectedBounds &protected_bounds) {
    const float offset = static_cast<float>(radius);
    const CaveRegionKey low = NativeProceduralCaveField::region_at(
        {position.x - offset, position.y, position.z - offset});
    const CaveRegionKey high = NativeProceduralCaveField::region_at(
        {position.x + offset, position.y, position.z + offset});
    for (std::int64_t z = low.z; z <= high.z; ++z) {
        for (std::int64_t x = low.x; x <= high.x; ++x) {
            const auto recipe = field.recipe_for_region(
                {static_cast<std::int32_t>(x), static_cast<std::int32_t>(z)},
                surface, protected_bounds);
            if (!recipe) continue;
            const CaveBounds &bounds = recipe->bounds;
            if (static_cast<double>(position.x) + radius >= bounds.position.x
                && static_cast<double>(position.x) - radius <= bounds.position.x + bounds.size.x
                && static_cast<double>(position.z) + radius >= bounds.position.z
                && static_cast<double>(position.z) - radius <= bounds.position.z + bounds.size.z)
                return true;
        }
    }
    return false;
}
} // namespace

VWB_TEST(native_procedural_cave_field_regions_match_script_floor_boundaries) {
    VWB_EXPECT((NativeProceduralCaveField::region_at({-96.0F, 0.0F, -96.0F}) == CaveRegionKey{0, 0}));
    VWB_EXPECT((NativeProceduralCaveField::region_at({-96.01F, 0.0F, -96.01F}) == CaveRegionKey{-1, -1}));
    VWB_EXPECT((NativeProceduralCaveField::region_at({96.0F, 0.0F, 96.0F}) == CaveRegionKey{1, 1}));
}

VWB_TEST(native_procedural_cave_field_footprint_bounds_match_recipe_reference_at_region_edges) {
    const NativeProceduralCaveField::SurfaceSampler surface = [](float, float) { return 60.0; };
    const NativeProceduralCaveField::ProtectedBounds unprotected = [](const CaveBounds &) { return false; };
    for (const std::string &seed : {"cave-contract-417", "atlas-39460628"}) {
        NativeProceduralCaveField field(cave_definition(seed));
        std::vector<CaveVector3> positions = {
            {-96.01F, 0.0F, -96.01F}, {-96.0F, 0.0F, -96.0F},
            {95.99F, 0.0F, 95.99F}, {96.0F, 0.0F, 96.0F},
            {-288.0F, 0.0F, 96.0F}, {288.0F, 0.0F, -96.0F},
        };
        for (std::int32_t z = -1; z <= 1; ++z) {
            for (std::int32_t x = -1; x <= 1; ++x) {
                const auto recipe = field.recipe_for_region({x, z}, surface, unprotected);
                if (!recipe) continue;
                const CaveBounds &bounds = recipe->bounds;
                positions.push_back(bounds.position);
                positions.push_back({bounds.position.x + bounds.size.x, 0.0F,
                    bounds.position.z + bounds.size.z});
                positions.push_back({bounds.position.x - 0.01F, 0.0F,
                    bounds.position.z - 0.01F});
                positions.push_back({bounds.position.x + bounds.size.x + 0.01F, 0.0F,
                    bounds.position.z + bounds.size.z + 0.01F});
            }
        }
        VWB_EXPECT(positions.size() > 6U);
        for (const CaveVector3 position : positions) {
            for (const double radius : {0.0, 0.01, 1.5, 8.0, 32.0, 96.0}) {
                const bool reference = footprint_intersects_recipe_bounds_reference(
                    field, position, radius, surface, unprotected);
                const bool actual = field.recipe_bounds_intersects_xz_footprint(
                    position, radius, surface, unprotected);
                VWB_EXPECT_MSG(actual == reference, seed);
            }
        }
    }
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
                VWB_EXPECT(recipe->chambers.size() >= 4U);
                VWB_EXPECT(recipe->deep_route.size() >= 5U);
                VWB_EXPECT(recipe->depth_loops.size() >= 1U);
                VWB_EXPECT(recipe->segments.front().radius == 2.5);
                VWB_EXPECT(recipe->segments.front().radius_end == 2.3);
                VWB_EXPECT(recipe->segments[1].radius == 2.3);
                VWB_EXPECT(recipe->segments[1].radius_end == 2.1);
                VWB_EXPECT(recipe->segments[1].vertical_radius == 1.2);
                VWB_EXPECT(recipe->segments[2].radius_end == 2.1);
                VWB_EXPECT(recipe->segments[3].radius == 2.1);
                VWB_EXPECT(recipe->segments[3].radius_end == 2.5);
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
    VWB_EXPECT(field.density(body, 60.0 - static_cast<double>(body.y), surface, unprotected) < 0.0);
    VWB_EXPECT(field.recipe_density(floor, *recipe) > 0.0);

    const CaveVector3 interior = recipe->route[3];
    VWB_EXPECT(field.recipe_density({interior.x, interior.y + 9.0F, interior.z}, *recipe) > 0.0);
}

VWB_TEST(native_procedural_cave_field_noise_cannot_undercut_recipe_route_floors) {
    const auto definition = cave_definition("cave-contract-417");
    NativeProceduralCaveField field(definition);
    const NativeProceduralCaveField::SurfaceSampler surface = [](float, float) { return 60.0; };
    const NativeProceduralCaveField::ProtectedBounds unprotected = [](const CaveBounds &) { return false; };
    std::optional<CaveRecipe> recipe;
    for (std::int32_t z = -8; z <= 8 && !recipe; ++z) {
        for (std::int32_t x = -8; x <= 8 && !recipe; ++x)
            recipe = field.recipe_for_region({x, z}, surface, unprotected);
    }
    VWB_EXPECT(recipe.has_value());
    if (!recipe) return;

    const auto check_recipe_owned_point = [&](const CaveVector3 point) {
        if (!recipe->bounds.contains(point)) return;
        const double carve = field.recipe_density(point, *recipe);
        const double effective = field.density(point,
            60.0 - static_cast<double>(point.y), surface, unprotected);
        VWB_EXPECT_MSG(effective >= carve - 0.25 && effective <= carve + 0.25,
            "recipe_density=" + std::to_string(carve) + ":effective=" + std::to_string(effective));
    };
    for (const CaveVector3 point : recipe->deep_route) check_recipe_owned_point(point);
    for (const auto &depth_loop : recipe->depth_loops)
        for (const CaveVector3 point : depth_loop) check_recipe_owned_point(point);
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
    VWB_EXPECT(recipe->segments[2].radius_end == 2.1);
    VWB_EXPECT(recipe->segments[3].radius == 2.1);
    VWB_EXPECT(recipe->segments[3].radius_end == 2.5);
    VWB_EXPECT(recipe->route.front().y < recipe->entry.y);
    VWB_EXPECT(recipe->chambers.size() >= 4U);
    // Frozen from the current visually verified atlas-1492 GDScript field,
    // region -1,-1. The prior region-0,0 oracle encoded an older straight
    // entrance and unbounded chamber profile and may now correctly reject.
    VWB_EXPECT(std::abs(recipe->entry.x + 211.376F) < 0.01F);
    VWB_EXPECT(std::abs(recipe->entry.y - 18.0466626F) < 0.01F);
    VWB_EXPECT(std::abs(recipe->entry.z + 153.9749F) < 0.01F);
    VWB_EXPECT(std::abs((recipe->route.front().y - recipe->entry.y) + 0.3375F) < 0.001F);
    VWB_EXPECT(recipe->deep_route.size() >= 9U);
    VWB_EXPECT(recipe->depth_loops.size() >= 4U);
    VWB_EXPECT(recipe->chambers.size() == recipe->depth_loops.size() + 3U);
    const double safe_floor = static_cast<double>(definition.constants().world_bottom_cell_y + 4)
        * definition.constants().cell_size_meters;
    const std::size_t expected_levels = std::min<std::size_t>(7U,
        static_cast<std::size_t>(std::floor((recipe->deep_route[2].y - safe_floor) / 18.0)));
    VWB_EXPECT(recipe->depth_loops.size() == expected_levels);
    VWB_EXPECT(recipe->entry.y - recipe->deep_route.back().y > 60.0F);
    VWB_EXPECT(recipe->chambers[0].radii.y >= 2.7F);
    VWB_EXPECT(recipe->chambers[1].radii.y >= 2.5F);
    const double roof_reserve = definition.constants().cell_size_meters + 1.1 + 0.24;
    for (const CaveChamber &chamber : recipe->chambers) {
        VWB_EXPECT(surface(chamber.center.x, chamber.center.z)
            - chamber.center.y - chamber.radii.y >= roof_reserve - 0.001);
        VWB_EXPECT(chamber.center.y - chamber.radii.y >= safe_floor - 0.001);
    }
    const CaveVector3 point{-21.0F * 1.35F, -1.0F * 1.35F, -4.0F * 1.35F};
    const double surface_y = surface(point.x, point.z);
    VWB_EXPECT_EQ(16.983000000000004, surface_y);
    const double first = field.density(point, surface_y - point.y, surface, unprotected);
    const double second = field.density(point, surface_y - point.y, surface, unprotected);
    VWB_EXPECT(std::isfinite(first));
    VWB_EXPECT_EQ(first, second);
}

VWB_TEST(native_procedural_cave_field_builds_common_connected_multilevel_networks) {
    const NativeProceduralCaveField::SurfaceSampler surface = [](float, float) { return 60.0; };
    const NativeProceduralCaveField::ProtectedBounds unprotected = [](const CaveBounds &) { return false; };
    std::size_t candidates = 0U;
    std::size_t accepted = 0U;
    std::size_t levels = 0U;
    double minimum_descent = std::numeric_limits<double>::infinity();
    for (const std::string seed : {"cave-depth-a", "cave-depth-b", "cave-depth-c", "cave-depth-d", "cave-depth-e"}) {
        NativeProceduralCaveField field(cave_definition(seed));
        std::size_t seed_candidates = 0U;
        std::size_t seed_accepted = 0U;
        std::size_t seed_levels = 0U;
        double seed_minimum_descent = std::numeric_limits<double>::infinity();
        for (std::int32_t z = -6; z <= 6; ++z) {
            for (std::int32_t x = -6; x <= 6; ++x) {
                ++candidates;
                ++seed_candidates;
                const auto recipe = field.recipe_for_region({x, z}, surface, unprotected);
                if (!recipe) continue;
                ++accepted;
                ++seed_accepted;
                const double descent = static_cast<double>(recipe->entry.y - recipe->deep_route.back().y);
                minimum_descent = std::min(minimum_descent, descent);
                seed_minimum_descent = std::min(seed_minimum_descent, descent);
                levels = std::min(levels == 0U ? recipe->depth_loops.size() : levels,
                    recipe->depth_loops.size());
                seed_levels = std::min(seed_levels == 0U ? recipe->depth_loops.size() : seed_levels,
                    recipe->depth_loops.size());
                VWB_EXPECT(recipe->depth_loops.size() >= 4U);
                VWB_EXPECT(recipe->depth_tier_links.size() >= 2U);
                VWB_EXPECT(recipe->depth_tier_links[0].from_tier != recipe->depth_tier_links[1].from_tier);
                VWB_EXPECT(recipe->chambers.size() == recipe->depth_loops.size() + 3U);
                // Seven lower levels plus the sampled cross-tier ramps need
                // at most 93 authored tunnel segments.
                VWB_EXPECT(recipe->segments.size() <= 96U);
                VWB_EXPECT((NativeProceduralCaveField::region_at(recipe->bounds.position) == recipe->region));
                const CaveVector3 bounds_end{recipe->bounds.position.x + recipe->bounds.size.x,
                    recipe->bounds.position.y + recipe->bounds.size.y,
                    recipe->bounds.position.z + recipe->bounds.size.z};
                VWB_EXPECT((NativeProceduralCaveField::region_at(bounds_end) == recipe->region));

                const auto find_supported_floor = [&](const CaveVector3 guide, const std::string &label)
                    -> std::optional<double> {
                    double air_y = static_cast<double>(guide.y) + 1.5;
                    double solid_y = air_y;
                    const double body_density = field.recipe_density(
                        {guide.x, static_cast<float>(air_y), guide.z}, *recipe);
                    VWB_EXPECT_MSG(body_density < 0.0,
                        label + ":body_not_clear:density=" + std::to_string(body_density)
                        + ":guide=" + std::to_string(guide.x) + "," + std::to_string(guide.y)
                        + "," + std::to_string(guide.z));
                    bool found_solid = false;
                    const double step = 0.25;
                    for (std::int32_t scan = 1; scan <= 80; ++scan) {
                        const double candidate_y = air_y - step;
                        const double density = field.recipe_density(
                            {guide.x, static_cast<float>(candidate_y), guide.z}, *recipe);
                        if (density > 0.0) {
                            solid_y = candidate_y;
                            found_solid = true;
                            break;
                        }
                        air_y = candidate_y;
                    }
                    VWB_EXPECT_MSG(found_solid,
                        label + ":no_solid_floor_within_20m:guide=" + std::to_string(guide.x)
                        + "," + std::to_string(guide.y) + "," + std::to_string(guide.z));
                    for (std::int32_t iteration = 0; iteration < 20; ++iteration) {
                        const double middle_y = (air_y + solid_y) * 0.5;
                        const double density = field.recipe_density(
                            {guide.x, static_cast<float>(middle_y), guide.z}, *recipe);
                        if (density < 0.0) air_y = middle_y;
                        else solid_y = middle_y;
                    }
                    const double floor_y = (air_y + solid_y) * 0.5;
                    std::string nearby = label + ":near=";
                    for (std::size_t i = 0U; i < recipe->segments.size(); ++i) {
                        const auto &segment = recipe->segments[i];
                        const double dx = static_cast<double>(segment.b.x - segment.a.x);
                        const double dz = static_cast<double>(segment.b.z - segment.a.z);
                        const double denom = std::max(dx * dx + dz * dz, 0.001);
                        const double t = std::clamp(((static_cast<double>(guide.x - segment.a.x) * dx)
                            + (static_cast<double>(guide.z - segment.a.z) * dz)) / denom, 0.0, 1.0);
                        const double px = segment.a.x + dx * t;
                        const double pz = segment.a.z + dz * t;
                        const double horizontal = std::hypot(guide.x - px, guide.z - pz);
                        if (horizontal < 7.0)
                            nearby += std::to_string(i) + "@" + std::to_string(horizontal)
                                + "/dy" + std::to_string((segment.a.y + (segment.b.y - segment.a.y) * t) - guide.y) + ";";
                    }
                    VWB_EXPECT_MSG(std::abs(floor_y - static_cast<double>(guide.y)) <= 1.6,
                        label + ":guide_floor_offset=" + std::to_string(floor_y - guide.y) + ":" + nearby);
                    const double support_density = field.recipe_density(
                        {guide.x, static_cast<float>(floor_y - 1.0), guide.z}, *recipe);
                    VWB_EXPECT_MSG(support_density > 0.0,
                        label + ":thin_or_missing_solid_support:density=" + std::to_string(support_density)
                        + ":floor=" + std::to_string(floor_y) + ":" + nearby);
                    constexpr double capsule_offsets[8][2] = {
                        {0.45, 0.0}, {-0.45, 0.0}, {0.0, 0.45}, {0.0, -0.45},
                        {0.3182, 0.3182}, {-0.3182, 0.3182}, {0.3182, -0.3182}, {-0.3182, -0.3182}};
                    for (const auto &offset : capsule_offsets) {
                        const CaveVector3 footprint{guide.x + static_cast<float>(offset[0]),
                            static_cast<float>(floor_y), guide.z + static_cast<float>(offset[1])};
                        VWB_EXPECT_MSG(field.recipe_density(
                            {footprint.x, static_cast<float>(floor_y + 1.8), footprint.z}, *recipe) < 0.0,
                            label + ":capsule_headroom_missing");
                        VWB_EXPECT_MSG(field.recipe_density(
                            {footprint.x, static_cast<float>(floor_y - 1.0), footprint.z}, *recipe) > 0.0,
                            label + ":capsule_footprint_unsupported");
                    }
                    return floor_y;
                };
                const auto check_walkable_path = [&](const std::vector<CaveVector3> &path, const std::string &path_name) {
                    std::optional<CaveVector3> previous_walkable;
                    for (std::size_t segment = 0U; segment + 1U < path.size(); ++segment) {
                        const CaveVector3 a = path[segment];
                        const CaveVector3 b = path[segment + 1U];
                        const double horizontal = std::hypot(static_cast<double>(b.x - a.x),
                            static_cast<double>(b.z - a.z));
                        const double grade = horizontal > 0.001
                            ? std::abs(static_cast<double>(b.y - a.y)) / horizontal
                            : std::numeric_limits<double>::infinity();
                        VWB_EXPECT(grade <= std::tan(46.0 * 3.14159265358979323846 / 180.0));
                        for (std::int32_t sample = 0; sample <= 8; ++sample) {
                            const double t = static_cast<double>(sample) / 8.0;
                            const CaveVector3 floor{a.x + static_cast<float>((b.x - a.x) * t),
                                a.y + static_cast<float>((b.y - a.y) * t),
                                a.z + static_cast<float>((b.z - a.z) * t)};
                            const std::string label = path_name + ":" + std::to_string(segment)
                                + ":" + std::to_string(sample);
                            const std::optional<double> walkable_floor = find_supported_floor(floor, label);
                            if (!walkable_floor) continue;
                            const CaveVector3 actual_floor{floor.x, static_cast<float>(*walkable_floor), floor.z};
                            if (previous_walkable) {
                                const double run = std::hypot(
                                    static_cast<double>(actual_floor.x - previous_walkable->x),
                                    static_cast<double>(actual_floor.z - previous_walkable->z));
                                if (run > 0.001) {
                                    const double actual_grade = std::abs(
                                        static_cast<double>(actual_floor.y - previous_walkable->y)) / run;
                                    VWB_EXPECT_MSG(actual_grade
                                        <= std::tan(46.0 * 3.14159265358979323846 / 180.0),
                                        label + ":actual_floor_grade=" + std::to_string(actual_grade));
                                }
                            }
                            previous_walkable = actual_floor;
                        }
                    }
                };
                check_walkable_path(recipe->deep_route, "deep_route");
                for (std::size_t loop_index = 0U; loop_index < recipe->depth_loops.size(); ++loop_index)
                    check_walkable_path(recipe->depth_loops[loop_index], "depth_loop_" + std::to_string(loop_index));
                for (const CaveChamber &chamber : recipe->chambers) {
                    const CaveVector3 floor{chamber.center.x,
                        chamber.center.y - chamber.radii.y, chamber.center.z};
                    VWB_EXPECT(find_supported_floor(floor, "chamber_floor").has_value());
                }
            }
        }
        std::cout << "CAVE_NETWORK_SEED seed=" << seed << " candidates=" << seed_candidates
            << " accepted=" << seed_accepted << " rate="
            << static_cast<double>(seed_accepted) / static_cast<double>(seed_candidates)
            << " minimum_levels=" << seed_levels << " minimum_descent=" << seed_minimum_descent << '\n';
        VWB_EXPECT(seed_accepted > seed_candidates / 2U);
        VWB_EXPECT(seed_levels >= 4U);
        VWB_EXPECT(seed_minimum_descent > 100.0);
    }
    std::cout << "CAVE_NETWORK_GRID candidates=" << candidates << " accepted=" << accepted
        << " rate=" << static_cast<double>(accepted) / static_cast<double>(candidates)
        << " minimum_levels=" << levels << " minimum_descent=" << minimum_descent << '\n';
    VWB_EXPECT(candidates == 845U);
    VWB_EXPECT(accepted > candidates / 2U);
    VWB_EXPECT(levels >= 4U);
    VWB_EXPECT(minimum_descent > 100.0);
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
    // The route values describe the cave floor; the old 16.2m probe sat below
    // that floor (17.56m) and therefore asserted that solid terrain was air.
    const CaveVector3 mouth_body{-432.0F, static_cast<float>(surface_y - 0.25), -16.2F};
    const double body_density = field.density(mouth_body,
        surface_y - mouth_body.y, surface, unprotected);
    const double recipe_density = field.recipe_density(mouth_body, *recipe);
    VWB_EXPECT_MSG(body_density < 0.0,
        "body=" + std::to_string(body_density) + ":recipe=" + std::to_string(recipe_density)
        + ":surface=" + std::to_string(surface_y));
}
