#include "test_harness.hpp"

#include "../core/native_tree_definition.hpp"

#include <limits>
#include <string>

using namespace voxel::world_backend;

namespace {

Sha256Digest digest(const std::uint8_t value) { Sha256Digest result{}; result.fill(value); return result; }

NativeTreeDefinitionInput natural_tree() {
    NativeTreeDefinitionInput input;
    input.schema_revision = 1U;
    input.producer_key = "surface-prop-manifest";
    input.producer_revision = 1U;
    input.source_recipe_digest = digest(1U);
    input.feature_kind = NativeTreeFeatureKind::natural_surface_tree;
    input.durable_feature_id = "seed:10,20:3";
    input.recipe_tree_id = input.durable_feature_id;
    input.world_seed = "seed";
    input.biome = "forest";
    input.family = "broadleaf_oak";
    input.growth_class = "standard";
    input.age_band = "mature";
    input.architecture = NativeTreeArchitecture::broadleaf;
    input.species_grammar = "bushy_oak";
    input.coordinate_frame = NativeTreeCoordinateFrame::world;
    input.position = {10.25, 71.0, 20.75};
    input.rotation_y = 0.25;
    input.ecology = {32.0, 20.0, 50.0, 0.65, 0.72, 2147483647};
    input.biome_parameters = {1U, 4.0, 12.0, 0.18, 0.8, 1.0, 6.0, 0.78, 0.4, 64.0, 48.0, 0.25};
    input.visual_height = 8.0;
    input.trunk_radius = 0.35;
    input.canopy_radius = 3.2;
    input.collision_height = 4.0;
    input.exclusion_margin = 0.25;
    return input;
}

NativeTreeDefinition site_tree() {
    NativeTreeDefinitionInput input = natural_tree();
    input.feature_kind = NativeTreeFeatureKind::site_tree;
    input.durable_feature_id = "site-tree:22:citadel-urban:14:local-tree-0001";
    input.recipe_tree_id = "citadel-urban-tree-0001";
    input.biome = "town";
    input.coordinate_frame = NativeTreeCoordinateFrame::owner_local;
    input.coordinate_owner_id = "site:citadel-urban";
    input.root_buttresses = {{{0.0, 0.0, 0.0}, {1.2, 0.1, -0.4}, 0.22, 0.08, "root_buttress"}};
    return NativeTreeDefinition::create(input);
}

} // namespace

VWB_TEST(native_tree_definition_preserves_separate_site_identity_frame_and_noncollision_buttresses) {
    const NativeTreeDefinition natural = NativeTreeDefinition::create(natural_tree());
    const NativeTreeDefinition site = site_tree();
    VWB_EXPECT_EQ(std::string("seed:10,20:3"), natural.input().durable_feature_id);
    VWB_EXPECT_EQ(NativeTreeCoordinateFrame::world, natural.input().coordinate_frame);
    VWB_EXPECT(natural.input().root_buttresses.empty());
    VWB_EXPECT_EQ(std::string("site-tree:22:citadel-urban:14:local-tree-0001"), site.input().durable_feature_id);
    VWB_EXPECT_EQ(std::string("citadel-urban-tree-0001"), site.input().recipe_tree_id);
    VWB_EXPECT_EQ(NativeTreeCoordinateFrame::owner_local, site.input().coordinate_frame);
    VWB_EXPECT_EQ(std::string("site:citadel-urban"), site.input().coordinate_owner_id);
    VWB_EXPECT_EQ(1U, site.input().root_buttresses.size());
    VWB_EXPECT_EQ(std::string("root_buttress"), site.input().root_buttresses[0].role);
    const NativeTreeTrunkCylinder cylinder = site.trunk_cylinder();
    VWB_EXPECT_EQ(0.35F, cylinder.radius);
    VWB_EXPECT_EQ(4.0F, cylinder.height);
    VWB_EXPECT_EQ(2.0F, cylinder.center_y);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('N'), site.canonical_binary()[0]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('T'), site.canonical_binary()[1]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('D'), site.canonical_binary()[2]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('1'), site.canonical_binary()[3]);
}

VWB_TEST(native_tree_definition_digest_covers_all_recipe_physical_and_interaction_facts) {
    const NativeTreeDefinition original = site_tree();
    NativeTreeDefinitionInput changed = original.input();
    changed.durable_feature_id += "x";
    VWB_EXPECT(original.content_digest() != NativeTreeDefinition::create(changed).content_digest());
    changed = original.input(); changed.recipe_tree_id += "x";
    VWB_EXPECT(original.content_digest() != NativeTreeDefinition::create(changed).content_digest());
    changed = original.input(); changed.coordinate_frame = NativeTreeCoordinateFrame::world; changed.coordinate_owner_id.clear();
    VWB_EXPECT(original.content_digest() != NativeTreeDefinition::create(changed).content_digest());
    changed = original.input(); changed.ecology.genetic_seed += 1;
    VWB_EXPECT(original.content_digest() != NativeTreeDefinition::create(changed).content_digest());
    changed = original.input(); changed.biome_parameters.wind_response += 0.1;
    VWB_EXPECT(original.content_digest() != NativeTreeDefinition::create(changed).content_digest());
    changed = original.input(); changed.collision_height = 3.5;
    VWB_EXPECT(original.content_digest() != NativeTreeDefinition::create(changed).content_digest());
    changed = original.input(); changed.root_buttresses[0].radius_end += 0.01;
    VWB_EXPECT(original.content_digest() != NativeTreeDefinition::create(changed).content_digest());
    VWB_EXPECT_EQ(original, site_tree());
}

VWB_TEST(native_tree_definition_rejects_incomplete_or_ambiguous_authority) {
    NativeTreeDefinitionInput malformed = natural_tree();
    malformed.durable_feature_id.clear();
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.recipe_tree_id = "different";
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.coordinate_frame = NativeTreeCoordinateFrame::owner_local;
    malformed.coordinate_owner_id = "site";
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.root_buttresses = {{{}, {1.0, 0.0, 0.0}, 0.2, 0.1, "root_buttress"}};
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = site_tree().input(); malformed.coordinate_owner_id.clear();
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.architecture = static_cast<NativeTreeArchitecture>(99);
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.species_grammar = std::string("bad\xc0\x80", 5);
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
}

VWB_TEST(native_tree_definition_rejects_nonfinite_invalid_dimensions_and_invalid_ecology) {
    NativeTreeDefinitionInput malformed = natural_tree();
    malformed.position.x = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.visual_height = 0.99;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.trunk_radius = 0.119;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.canopy_radius = 0.34;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.collision_height = 8.1;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.exclusion_margin = -0.1;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.ecology.age_years = 51.0;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.ecology.local_maturity = 1.01;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = natural_tree(); malformed.biome_parameters.height_min = 13.0;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
    malformed = site_tree().input(); malformed.root_buttresses[0].radius_end = 0.0;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(malformed));
}

VWB_TEST(native_tree_definition_enforces_bounded_canonical_admission) {
    NativeTreeDefinitionLimits limits;
    limits.max_text_bytes = 4U;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(natural_tree(), limits));
    limits = {}; limits.max_buttresses = 1U;
    NativeTreeDefinitionInput over_limit = site_tree().input();
    over_limit.root_buttresses.push_back(over_limit.root_buttresses[0]);
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(over_limit, limits));
    const NativeTreeDefinition accepted = NativeTreeDefinition::create(natural_tree());
    limits = {}; limits.max_canonical_bytes = accepted.canonical_binary().size();
    VWB_EXPECT_EQ(accepted.canonical_binary(), NativeTreeDefinition::create(natural_tree(), limits).canonical_binary());
    limits.max_canonical_bytes -= 1U;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(natural_tree(), limits));
}

VWB_TEST(native_tree_definition_exhaustively_rejects_each_scalar_boundary) {
    const auto rejects = [](NativeTreeDefinitionInput input) {
        VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(input));
    };
    NativeTreeDefinitionLimits bad_limits;
    bad_limits.max_text_bytes = 0U;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(natural_tree(), bad_limits));
    bad_limits = {}; bad_limits.max_buttresses = 0U;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(natural_tree(), bad_limits));
    bad_limits = {}; bad_limits.max_canonical_bytes = 0U;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(natural_tree(), bad_limits));
    bad_limits = {}; bad_limits.max_text_bytes = static_cast<std::size_t>(std::numeric_limits<std::uint32_t>::max()) + 1U;
    VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(natural_tree(), bad_limits));

    NativeTreeDefinitionInput value = natural_tree(); value.schema_revision = 0U; rejects(value);
    value = natural_tree(); value.producer_revision = 0U; rejects(value);
    value = natural_tree(); value.source_recipe_digest = {}; rejects(value);
    value = natural_tree(); value.feature_kind = static_cast<NativeTreeFeatureKind>(99); rejects(value);
    value = natural_tree(); value.architecture = static_cast<NativeTreeArchitecture>(99); rejects(value);
    value = natural_tree(); value.coordinate_frame = static_cast<NativeTreeCoordinateFrame>(99); rejects(value);
    for (const int field : {0, 1, 2, 3, 4, 5, 6, 7, 8}) {
        value = natural_tree();
        switch (field) {
        case 0: value.producer_key.clear(); break;
        case 1: value.durable_feature_id.clear(); break;
        case 2: value.recipe_tree_id.clear(); break;
        case 3: value.world_seed.clear(); break;
        case 4: value.biome.clear(); break;
        case 5: value.family.clear(); break;
        case 6: value.growth_class.clear(); break;
        case 7: value.age_band.clear(); break;
        default: value.species_grammar.clear(); break;
        }
        rejects(value);
    }
    value = natural_tree(); value.coordinate_owner_id = "unexpected"; rejects(value);
    value = site_tree().input(); value.coordinate_owner_id.clear(); rejects(value);
    value = natural_tree(); value.coordinate_frame = NativeTreeCoordinateFrame::owner_local; value.coordinate_owner_id = "site"; rejects(value);
    value = natural_tree(); value.durable_feature_id = "different"; rejects(value);
    value = natural_tree(); value.root_buttresses = {{{}, {1.0, 0.0, 0.0}, 0.2, 0.1, "root_buttress"}}; rejects(value);

    value = natural_tree(); value.position.x = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = natural_tree(); value.position.y = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = natural_tree(); value.position.z = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = natural_tree(); value.rotation_y = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = natural_tree(); value.ecology.age_years = -1.0; rejects(value);
    value = natural_tree(); value.ecology.age_range_min = -1.0; rejects(value);
    value = natural_tree(); value.ecology.age_range_max = -1.0; rejects(value);
    value = natural_tree(); value.ecology.age_range_min = 51.0; rejects(value);
    value = natural_tree(); value.ecology.age_years = 19.0; rejects(value);
    value = natural_tree(); value.ecology.age_years = 51.0; rejects(value);
    value = natural_tree(); value.ecology.local_maturity = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = natural_tree(); value.ecology.local_maturity = -0.01; rejects(value);
    value = natural_tree(); value.ecology.local_maturity = 1.01; rejects(value);
    value = natural_tree(); value.ecology.growth_stage = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = natural_tree(); value.ecology.growth_stage = -0.01; rejects(value);
    value = natural_tree(); value.ecology.growth_stage = 1.01; rejects(value);
    value = natural_tree(); value.ecology.age_years = -std::numeric_limits<double>::infinity(); rejects(value);
    value = site_tree().input(); value.root_buttresses[0].radius_start = std::numeric_limits<double>::infinity(); rejects(value);
    value = natural_tree(); value.architecture = NativeTreeArchitecture::conifer;
    VWB_EXPECT(NativeTreeDefinition::create(value).input().architecture == NativeTreeArchitecture::conifer);
    value = natural_tree(); value.architecture = NativeTreeArchitecture::savanna;
    VWB_EXPECT(NativeTreeDefinition::create(value).input().architecture == NativeTreeArchitecture::savanna);
}

VWB_TEST(native_tree_definition_exhaustively_rejects_biome_dimensions_and_buttress_boundaries) {
    const auto rejects = [](NativeTreeDefinitionInput input) {
        VWB_EXPECT_THROW(NativeTreeDefinitionRejected, NativeTreeDefinition::create(input));
    };
    NativeTreeDefinitionInput value = natural_tree(); value.biome_parameters.revision = 0U; rejects(value);
    value = natural_tree(); value.biome_parameters.height_min = -1.0; rejects(value);
    value = natural_tree(); value.biome_parameters.height_max = -1.0; rejects(value);
    value = natural_tree(); value.biome_parameters.height_min = 13.0; rejects(value);
    value = natural_tree(); value.biome_parameters.trunk_radius_min = -1.0; rejects(value);
    value = natural_tree(); value.biome_parameters.trunk_radius_max = -1.0; rejects(value);
    value = natural_tree(); value.biome_parameters.trunk_radius_min = 1.0; rejects(value);
    value = natural_tree(); value.biome_parameters.canopy_radius_min = -1.0; rejects(value);
    value = natural_tree(); value.biome_parameters.canopy_radius_max = -1.0; rejects(value);
    value = natural_tree(); value.biome_parameters.canopy_radius_min = 7.0; rejects(value);
    value = natural_tree(); value.biome_parameters.canopy_density = -1.0; rejects(value);
    value = natural_tree(); value.biome_parameters.wind_response = -1.0; rejects(value);
    value = natural_tree(); value.biome_parameters.visibility_range = -1.0; rejects(value);
    value = natural_tree(); value.biome_parameters.shadow_range = -1.0; rejects(value);
    value = natural_tree(); value.biome_parameters.exclusion_margin = -1.0; rejects(value);

    value = natural_tree(); value.visual_height = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = natural_tree(); value.visual_height = 0.99; rejects(value);
    value = natural_tree(); value.trunk_radius = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = natural_tree(); value.trunk_radius = 0.119; rejects(value);
    value = natural_tree(); value.canopy_radius = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = natural_tree(); value.canopy_radius = 0.34; rejects(value);
    value = natural_tree(); value.collision_height = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = natural_tree(); value.collision_height = 0.99; rejects(value);
    value = natural_tree(); value.collision_height = 8.01; rejects(value);
    value = natural_tree(); value.exclusion_margin = -0.01; rejects(value);
    value = natural_tree(); value.visual_height = 1.0e100; value.canopy_radius = 1.0e100; value.collision_height = 1.0e100; value.trunk_radius = 1.0e100; rejects(value);
    value = natural_tree(); value.visual_height = 1.0e100; value.collision_height = 1.0e100; rejects(value);

    value = site_tree().input(); value.root_buttresses[0].start.x = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = site_tree().input(); value.root_buttresses[0].start.y = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = site_tree().input(); value.root_buttresses[0].start.z = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = site_tree().input(); value.root_buttresses[0].end.x = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = site_tree().input(); value.root_buttresses[0].end.y = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = site_tree().input(); value.root_buttresses[0].end.z = std::numeric_limits<double>::quiet_NaN(); rejects(value);
    value = site_tree().input(); value.root_buttresses[0].radius_start = 0.0; rejects(value);
    value = site_tree().input(); value.root_buttresses[0].radius_end = 0.0; rejects(value);
    value = site_tree().input(); value.root_buttresses[0].role.clear(); rejects(value);
}

VWB_TEST(native_tree_definition_value_equality_covers_every_declared_field) {
    const NativeTreePoint3 point{1.0, 2.0, 3.0};
    VWB_EXPECT(point == point); VWB_EXPECT(!(point == NativeTreePoint3{9.0, 2.0, 3.0}));
    VWB_EXPECT(!(point == NativeTreePoint3{1.0, 9.0, 3.0})); VWB_EXPECT(!(point == NativeTreePoint3{1.0, 2.0, 9.0}));
    const NativeTreeButtressFootprint buttress = site_tree().input().root_buttresses[0];
    VWB_EXPECT(buttress == buttress); NativeTreeButtressFootprint altered_buttress = buttress;
    altered_buttress.start.x += 1.0; VWB_EXPECT(!(buttress == altered_buttress)); altered_buttress = buttress;
    altered_buttress.end.x += 1.0; VWB_EXPECT(!(buttress == altered_buttress)); altered_buttress = buttress;
    altered_buttress.radius_start += 1.0; VWB_EXPECT(!(buttress == altered_buttress)); altered_buttress = buttress;
    altered_buttress.radius_end += 1.0; VWB_EXPECT(!(buttress == altered_buttress)); altered_buttress = buttress;
    altered_buttress.role += "x"; VWB_EXPECT(!(buttress == altered_buttress));
    const NativeTreeEcology ecology = natural_tree().ecology; VWB_EXPECT(ecology == ecology);
    NativeTreeEcology altered_ecology = ecology;
    altered_ecology.age_years += 1.0; VWB_EXPECT(!(ecology == altered_ecology)); altered_ecology = ecology;
    altered_ecology.age_range_min += 1.0; VWB_EXPECT(!(ecology == altered_ecology)); altered_ecology = ecology;
    altered_ecology.age_range_max += 1.0; VWB_EXPECT(!(ecology == altered_ecology)); altered_ecology = ecology;
    altered_ecology.local_maturity += 1.0; VWB_EXPECT(!(ecology == altered_ecology)); altered_ecology = ecology;
    altered_ecology.growth_stage += 1.0; VWB_EXPECT(!(ecology == altered_ecology)); altered_ecology = ecology;
    altered_ecology.genetic_seed += 1; VWB_EXPECT(!(ecology == altered_ecology));
    const NativeTreeBiomeParameters parameters = natural_tree().biome_parameters; VWB_EXPECT(parameters == parameters);
    NativeTreeBiomeParameters altered_parameters = parameters;
    for (const int field : {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}) {
        altered_parameters = parameters;
        switch (field) {
        case 0: ++altered_parameters.revision; break; case 1: altered_parameters.height_min += 1.0; break;
        case 2: altered_parameters.height_max += 1.0; break; case 3: altered_parameters.trunk_radius_min += 1.0; break;
        case 4: altered_parameters.trunk_radius_max += 1.0; break; case 5: altered_parameters.canopy_radius_min += 1.0; break;
        case 6: altered_parameters.canopy_radius_max += 1.0; break; case 7: altered_parameters.canopy_density += 1.0; break;
        case 8: altered_parameters.wind_response += 1.0; break; case 9: altered_parameters.visibility_range += 1.0; break;
        case 10: altered_parameters.shadow_range += 1.0; break; default: altered_parameters.exclusion_margin += 1.0; break;
        }
        VWB_EXPECT(!(parameters == altered_parameters));
    }
    const NativeTreeTrunkCylinder cylinder{0.2F, 2.0F, 1.0F}; VWB_EXPECT(cylinder == cylinder);
    VWB_EXPECT(!(cylinder == NativeTreeTrunkCylinder{0.3F, 2.0F, 1.0F}));
    VWB_EXPECT(!(cylinder == NativeTreeTrunkCylinder{0.2F, 3.0F, 1.0F}));
    VWB_EXPECT(!(cylinder == NativeTreeTrunkCylinder{0.2F, 2.0F, 2.0F}));
    const NativeTreeDefinitionInput input = site_tree().input(); VWB_EXPECT(input == input);
    NativeTreeDefinitionInput altered_input = input; altered_input.producer_key += "x";
    VWB_EXPECT(!(input == altered_input)); altered_input = input; altered_input.old_growth = true;
    VWB_EXPECT(!(input == altered_input)); altered_input = input; altered_input.rotation_y += 1.0;
    VWB_EXPECT(!(input == altered_input)); altered_input = input; altered_input.root_buttresses.clear();
    VWB_EXPECT(!(input == altered_input));
    for (const int field : {
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
            15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
        }) {
        altered_input = input;
        switch (field) {
        case 0: ++altered_input.schema_revision; break;
        case 1: altered_input.producer_key += "x"; break;
        case 2: ++altered_input.producer_revision; break;
        case 3: ++altered_input.source_recipe_digest[0]; break;
        case 4: altered_input.feature_kind = NativeTreeFeatureKind::natural_surface_tree; break;
        case 5: altered_input.durable_feature_id += "x"; break;
        case 6: altered_input.recipe_tree_id += "x"; break;
        case 7: altered_input.world_seed += "x"; break;
        case 8: altered_input.biome += "x"; break;
        case 9: altered_input.family += "x"; break;
        case 10: altered_input.growth_class += "x"; break;
        case 11: altered_input.age_band += "x"; break;
        case 12: altered_input.architecture = NativeTreeArchitecture::conifer; break;
        case 13: altered_input.species_grammar += "x"; break;
        case 14: altered_input.coordinate_frame = NativeTreeCoordinateFrame::world; break;
        case 15: altered_input.coordinate_owner_id += "x"; break;
        case 16: altered_input.position.x += 1.0; break;
        case 17: altered_input.rotation_y += 1.0; break;
        case 18: altered_input.ecology.age_years += 1.0; break;
        case 19: ++altered_input.biome_parameters.revision; break;
        case 20: altered_input.visual_height += 1.0; break;
        case 21: altered_input.trunk_radius += 1.0; break;
        case 22: altered_input.canopy_radius += 1.0; break;
        case 23: altered_input.collision_height += 1.0; break;
        case 24: altered_input.exclusion_margin += 1.0; break;
        case 25: altered_input.old_growth = !altered_input.old_growth; break;
        case 26: altered_input.root_buttresses.clear(); break;
        case 27: altered_input.position.y += 1.0; break;
        default: altered_input.position.z += 1.0; break;
        }
        VWB_EXPECT(!(input == altered_input));
    }
    NativeTreeDefinitionInput old_growth_input = natural_tree(); old_growth_input.old_growth = true;
    VWB_EXPECT(NativeTreeDefinition::create(old_growth_input).content_digest()
        != NativeTreeDefinition::create(natural_tree()).content_digest());
    const NativeTreeDefinition site = site_tree(); VWB_EXPECT(site == site); VWB_EXPECT(!(site != site));
    VWB_EXPECT(site != NativeTreeDefinition::create(natural_tree()));
}
