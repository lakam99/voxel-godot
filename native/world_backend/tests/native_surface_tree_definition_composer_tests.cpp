#include "test_harness.hpp"

#include "../core/native_surface_tree_definition_composer.hpp"
#include "../core/legacy_seed_hash.hpp"
#include "native_surface_prop_test_fixture.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <limits>

using namespace voxel::world_backend;

namespace {

NativeSurfacePropAttemptStream attempts(const std::string &seed = "tree-composer") {
    return NativeSurfacePropAttemptStream::create(admit_raw_terrain_seed(seed), -2, 3);
}

NativeSurfacePropBaselineInput input_for(const NativeSurfacePropAttempt &attempt,
    const NativeSurfacePropTreeCompatibilityFamily family) {
    NativeSurfacePropBaselineInput result;
    result.classification.ordinal = attempt.ordinal;
    result.classification.cell_x = attempt.cell_x;
    result.classification.cell_z = attempt.cell_z;
    result.classification.source_decision_digest.fill(static_cast<std::uint8_t>(attempt.ordinal + 1U));
    result.classification.admission = NativeSurfacePropAdmission::eligible;
    result.classification.policy.tree_upper = 1.0F;
    result.classification.policy.forage_upper = 1.0F;
    result.classification.policy.wildlife_upper = 1.0F;
    result.classification.policy.tree_family = family;
    return result;
}

NativeSurfacePropBaselineStream baseline(const NativeSurfacePropAttemptStream &source,
    const NativeSurfacePropTreeCompatibilityFamily family = NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw) {
    std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> inputs{};
    for (std::size_t index = 0U; index < inputs.size(); ++index) inputs[index] = input_for(source.attempts()[index], family);
    return NativeSurfacePropBaselineStream::create(source, inputs);
}

WorldSourceDefinition world_source(const std::string &seed = "tree-composer") {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
    descriptor.revisions.terrain_generator_revision = 3U; descriptor.revisions.lattice_query_revision = 5U;
    return WorldSourceDefinition(std::move(descriptor));
}

NativeSurfacePropPlacementSet placements(const NativeSurfacePropAttemptStream &source,
    const NativeSurfacePropBaselineStream &stream, const WorldSourceDefinition &source_definition = world_source()) {
    NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        source_definition, {-1, 0}, surface_prop_test_fixture::empty_deltas()));
    return NativeSurfacePropPlacementSet::create(
        source, stream, surface_prop_test_fixture::receipt(terrain.pin()), terrain);
}

NativeSurfaceTreeEcologyProfile profile(const std::string &biome, const std::string &family) {
    NativeSurfaceTreeEcologyProfile result;
    result.schema_revision = 1U; result.profile_revision = 1U; result.source_profile_digest.fill(8U);
    result.source_biome = biome; result.profile_id = biome; result.tree_families = {family};
    result.tree_scale = 1.0; result.height_min = 18.0; result.height_max = 82.0;
    result.trunk_radius_min = 0.55; result.trunk_radius_max = 7.2;
    result.canopy_radius_min = 6.0; result.canopy_radius_max = 34.0;
    result.canopy_density = 0.82; result.wind_response = 1.15; result.visibility_range = 340.0;
    result.shadow_range = 210.0; result.exclusion_margin = 0.45;
    result.age_min_years = 30.0; result.age_typical_years = 170.0; result.age_max_years = 380.0;
    result.maturity_cell_scale = 220.0; result.maturity_influence = 0.82; result.local_age_span = 0.34;
    result.age_distribution_skew = 0.72; result.age_band_thresholds = {0.10, 0.27, 0.55, 0.82};
    result.height_growth_exponent = 0.62; result.girth_growth_exponent = 0.82; result.crown_growth_exponent = 0.58;
    return result;
}

NativeTreeDefinition compose(const NativeSurfacePropTreeCompatibilityFamily family,
    const NativeSurfaceTreeEcologyProfile &tree_profile, const std::uint32_t ordinal = 0U) {
    const NativeSurfacePropAttemptStream source = attempts();
    const NativeSurfacePropBaselineStream stream = baseline(source, family);
    const NativeSurfacePropPlacementSet set = placements(source, stream);
    return NativeSurfaceTreeDefinitionComposer::create(set, stream, ordinal, world_source(), tree_profile);
}

} // namespace

VWB_TEST(native_surface_tree_definition_composer_binds_a_broadleaf_definition_to_one_anchored_source_attempt) {
    const NativeSurfacePropAttemptStream source = attempts(); const NativeSurfacePropBaselineStream stream = baseline(source);
    const NativeSurfacePropPlacementSet set = placements(source, stream); const NativeSurfaceTreeEcologyProfile forest = profile("forest", "ecological_broadleaf_tree");
    const NativeTreeDefinition tree = NativeSurfaceTreeDefinitionComposer::create(set, stream, 0U, world_source(), forest);
    const NativeTreeDefinitionInput &input = tree.input(); const NativeSurfacePropPlacementEntry &placement = set.entries()[0];
    VWB_EXPECT_EQ(std::string("native_surface_tree_recipe"), input.producer_key);
    VWB_EXPECT_EQ(NativeTreeFeatureKind::natural_surface_tree, input.feature_kind);
    VWB_EXPECT_EQ(placement.durable_id, input.durable_feature_id); VWB_EXPECT_EQ(placement.durable_id, input.recipe_tree_id);
    VWB_EXPECT_EQ(std::string("forest"), input.biome); VWB_EXPECT_EQ(std::string("ecological_broadleaf_tree"), input.family);
    VWB_EXPECT_EQ(NativeTreeArchitecture::broadleaf, input.architecture); VWB_EXPECT_EQ(std::string("bushy_oak"), input.species_grammar);
    VWB_EXPECT_EQ(static_cast<double>(placement.world_anchor.x), input.position.x); VWB_EXPECT_EQ(static_cast<double>(placement.world_anchor.y), input.position.y);
    VWB_EXPECT_EQ(static_cast<double>(placement.world_anchor.z), input.position.z); VWB_EXPECT(input.visual_height >= 18.0);
    VWB_EXPECT(input.trunk_radius >= 0.55 && input.trunk_radius <= 7.2); VWB_EXPECT(input.canopy_radius >= input.trunk_radius * 2.2);
    VWB_EXPECT(input.collision_height >= 2.0 && input.collision_height <= input.visual_height);
    const NativeTreeTrunkCylinder cylinder = tree.trunk_cylinder();
    VWB_EXPECT_EQ(static_cast<float>(input.trunk_radius), cylinder.radius); VWB_EXPECT_EQ(static_cast<float>(input.collision_height), cylinder.height);
    VWB_EXPECT_EQ(cylinder.height * 0.5F, cylinder.center_y);
}

VWB_TEST(native_surface_tree_definition_composer_replays_conifer_and_savanna_physical_semantics) {
    const NativeTreeDefinition conifer = compose(NativeSurfacePropTreeCompatibilityFamily::conifer_22_draw,
        profile("taiga", "ecological_conifer_tree"));
    const NativeTreeDefinition savanna = compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw,
        profile("savanna", "ecological_savanna_tree"));
    VWB_EXPECT_EQ(NativeTreeArchitecture::conifer, conifer.input().architecture); VWB_EXPECT_EQ(std::string("norway_spruce"), conifer.input().species_grammar);
    VWB_EXPECT_EQ(NativeTreeArchitecture::savanna, savanna.input().architecture); VWB_EXPECT_EQ(std::string("umbrella_thorn"), savanna.input().species_grammar);
    VWB_EXPECT(std::fabs(conifer.input().collision_height - std::max(2.0, conifer.input().visual_height * 0.82)) < 0.0000001);
    VWB_EXPECT(std::fabs(savanna.input().collision_height - std::max(2.0, savanna.input().visual_height * 0.52)) < 0.0000001);
    VWB_EXPECT(conifer.content_digest() != savanna.content_digest());
}

VWB_TEST(native_surface_tree_definition_composer_is_deterministic_and_binds_all_source_identity_inputs) {
    const NativeSurfaceTreeEcologyProfile forest = profile("forest", "ecological_broadleaf_tree");
    const NativeTreeDefinition first = compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, forest, 3U);
    const NativeTreeDefinition second = compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, forest, 3U);
    VWB_EXPECT_EQ(first.canonical_binary(), second.canonical_binary()); VWB_EXPECT_EQ(first.content_digest(), second.content_digest());
    NativeSurfaceTreeEcologyProfile changed = forest; changed.source_profile_digest[0] = 9U;
    VWB_EXPECT(first.content_digest() != compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, changed, 3U).content_digest());
    changed = forest; ++changed.profile_revision;
    VWB_EXPECT(first.content_digest() != compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, changed, 3U).content_digest());
    changed = forest; changed.tree_families = {"ecological_savanna_tree"};
    VWB_EXPECT(first.content_digest() != compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, changed, 3U).content_digest());
}

VWB_TEST(native_surface_tree_definition_composer_keeps_raw_family_seed_separate_from_normalized_ecology_seed) {
    const std::string raw_seed = "  native-tree-seed-0  ";
    const NativeSurfacePropAttemptStream source = attempts(raw_seed);
    const NativeSurfacePropBaselineStream stream = baseline(source);
    const WorldSourceDefinition source_definition = world_source(raw_seed);
    const NativeSurfacePropPlacementSet set = placements(source, stream, source_definition);
    NativeSurfaceTreeEcologyProfile plains = profile("plains", "ecological_broadleaf_tree_0");
    plains.tree_scale = 0.98; plains.height_min = 7.0; plains.height_max = 18.0;
    plains.trunk_radius_min = 0.24; plains.trunk_radius_max = 0.72;
    plains.canopy_radius_min = 2.8; plains.canopy_radius_max = 7.5;
    plains.age_min_years = 5.0; plains.age_typical_years = 35.0; plains.age_max_years = 100.0;
    plains.maturity_cell_scale = 260.0; plains.maturity_influence = 0.58; plains.local_age_span = 0.42;
    plains.age_distribution_skew = 1.08; plains.age_band_thresholds = {0.20, 0.46, 0.72, 0.91};
    plains.height_growth_exponent = 0.82; plains.girth_growth_exponent = 1.02; plains.crown_growth_exponent = 0.82;
    plains.tree_families = {"ecological_broadleaf_tree_0", "ecological_broadleaf_tree_1", "ecological_broadleaf_tree_2",
        "ecological_broadleaf_tree_3", "ecological_broadleaf_tree_4", "ecological_broadleaf_tree_5", "ecological_broadleaf_tree_6"};
    bool found_distinct_index = false;
    for (std::uint32_t ordinal = 0U; ordinal < NativeSurfacePropAttemptStream::ATTEMPT_COUNT; ++ordinal) {
        const std::string &prop_id = set.entries()[ordinal].durable_id;
        const std::uint32_t raw_index = legacy_seed_hash(admit_raw_terrain_seed("tree-family:" + raw_seed + ":plains:" + prop_id).code_points)
            % static_cast<std::uint32_t>(plains.tree_families.size());
        const std::string normalized_seed = BiomeRegionField::admit_utf8_seed(raw_seed).utf8;
        const std::uint32_t normalized_index = legacy_seed_hash(admit_raw_terrain_seed("tree-family:" + normalized_seed + ":plains:" + prop_id).code_points)
            % static_cast<std::uint32_t>(plains.tree_families.size());
        if (raw_index == normalized_index) continue;
        found_distinct_index = true;
        const NativeTreeDefinition tree = NativeSurfaceTreeDefinitionComposer::create(set, stream, ordinal, source_definition, plains);
        VWB_EXPECT_EQ(plains.tree_families[raw_index], tree.input().family);
        VWB_EXPECT_EQ(raw_seed, tree.input().world_seed);
        break;
    }
    VWB_EXPECT(found_distinct_index);
}

VWB_TEST(native_surface_tree_definition_composer_rejects_unbound_tree_profiles_and_cross_stream_mismatches) {
    const NativeSurfacePropAttemptStream source = attempts(); NativeSurfacePropBaselineStream stream = baseline(source);
    const NativeSurfacePropPlacementSet set = placements(source, stream); const NativeSurfaceTreeEcologyProfile forest = profile("forest", "ecological_broadleaf_tree");
    const auto rejects = [&](const NativeSurfacePropPlacementSet &placement_value, const NativeSurfacePropBaselineStream &baseline_value,
        const std::uint32_t ordinal, const WorldSourceDefinition &source_value, const NativeSurfaceTreeEcologyProfile &profile_value) {
        VWB_EXPECT_THROW(NativeSurfaceTreeDefinitionComposerRejected,
            NativeSurfaceTreeDefinitionComposer::create(placement_value, baseline_value, ordinal, source_value, profile_value));
    };
    rejects(set, stream, NativeSurfacePropAttemptStream::ATTEMPT_COUNT, world_source(), forest);
    WorldSourceDescriptor changed_descriptor; changed_descriptor.raw_terrain_seed = admit_raw_terrain_seed("other"); changed_descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("other");
    rejects(set, stream, 0U, WorldSourceDefinition(changed_descriptor), forest);
    NativeSurfaceTreeEcologyProfile malformed = forest; malformed.schema_revision = 0U; rejects(set, stream, 0U, world_source(), malformed);
    malformed = forest; malformed.source_profile_digest = {}; rejects(set, stream, 0U, world_source(), malformed);
    malformed = forest; malformed.tree_families.clear(); rejects(set, stream, 0U, world_source(), malformed);
    malformed = forest; malformed.tree_families = {"not_a_tree"}; rejects(set, stream, 0U, world_source(), malformed);
    malformed = forest; malformed.age_band_thresholds[2] = malformed.age_band_thresholds[1]; rejects(set, stream, 0U, world_source(), malformed);
    malformed = forest; malformed.tree_scale = 0.0; rejects(set, stream, 0U, world_source(), malformed);
    malformed = forest; malformed.maturity_cell_scale = 7.0; rejects(set, stream, 0U, world_source(), malformed);
    malformed = forest; malformed.age_distribution_skew = std::numeric_limits<double>::infinity(); rejects(set, stream, 0U, world_source(), malformed);
    auto &corrupt_placement = const_cast<NativeSurfacePropPlacementEntry &>(set.entries()[0]);
    corrupt_placement.presence = NativeSurfacePropPlacementPresence::absent; rejects(set, stream, 0U, world_source(), forest);
}

VWB_TEST(native_surface_tree_definition_composer_exhaustively_rejects_profile_boundaries_and_malformed_tree_replays) {
    const NativeSurfacePropAttemptStream source = attempts(); const NativeSurfacePropBaselineStream original = baseline(source);
    const NativeSurfacePropPlacementSet set = placements(source, original); const NativeSurfaceTreeEcologyProfile forest = profile("forest", "ecological_broadleaf_tree");
    const auto reject_profile = [&](NativeSurfaceTreeEcologyProfile value) {
        VWB_EXPECT_THROW(NativeSurfaceTreeDefinitionComposerRejected,
            NativeSurfaceTreeDefinitionComposer::create(set, original, 0U, world_source(), value));
    };
    NativeSurfaceTreeEcologyProfile bad = forest; bad.profile_revision = 0U; reject_profile(bad);
    bad = forest; bad.source_biome.clear(); reject_profile(bad);
    bad = forest; bad.source_biome = std::string(1U, static_cast<char>(0xff)); reject_profile(bad);
    // NativeValue admits NUL as UTF-8 text, but the seed-hash decoder rejects it.
    bad = forest; bad.source_biome = std::string("forest\0extra", 12U); reject_profile(bad);
    // The profile admits up to NativeValue's text limit; the tree definition has
    // a stricter 4 KiB durable-text contract, which the composer must preserve.
    bad = forest; bad.source_biome.assign(4097U, 'f'); reject_profile(bad);
    bad = forest; bad.profile_id.clear(); reject_profile(bad);
    bad = forest; bad.tree_families.assign(65U, "ecological_broadleaf_tree"); reject_profile(bad);
    bad = forest; bad.tree_families = {""}; reject_profile(bad);
    bad = forest; bad.height_min = -0.1; reject_profile(bad);
    bad = forest; bad.height_max = -0.1; reject_profile(bad);
    bad = forest; bad.height_min = bad.height_max + 0.1; reject_profile(bad);
    bad = forest; bad.trunk_radius_min = -0.1; reject_profile(bad);
    bad = forest; bad.trunk_radius_max = -0.1; reject_profile(bad);
    bad = forest; bad.trunk_radius_min = bad.trunk_radius_max + 0.1; reject_profile(bad);
    bad = forest; bad.canopy_radius_min = -0.1; reject_profile(bad);
    bad = forest; bad.canopy_radius_max = -0.1; reject_profile(bad);
    bad = forest; bad.canopy_radius_min = bad.canopy_radius_max + 0.1; reject_profile(bad);
    bad = forest; bad.canopy_density = -0.1; reject_profile(bad);
    bad = forest; bad.wind_response = -0.1; reject_profile(bad);
    bad = forest; bad.visibility_range = -0.1; reject_profile(bad);
    bad = forest; bad.shadow_range = -0.1; reject_profile(bad);
    bad = forest; bad.exclusion_margin = -0.1; reject_profile(bad);
    bad = forest; bad.age_min_years = -0.1; reject_profile(bad);
    bad = forest; bad.age_typical_years = -0.1; reject_profile(bad);
    bad = forest; bad.age_max_years = -0.1; reject_profile(bad);
    bad = forest; bad.age_typical_years = bad.age_min_years - 0.1; reject_profile(bad);
    bad = forest; bad.age_max_years = bad.age_typical_years - 0.1; reject_profile(bad);
    bad = forest; bad.maturity_cell_scale = std::numeric_limits<double>::infinity(); reject_profile(bad);
    bad = forest; bad.tree_scale = std::numeric_limits<double>::quiet_NaN(); reject_profile(bad);
    bad = forest; bad.height_min = std::numeric_limits<double>::quiet_NaN(); reject_profile(bad);
    bad = forest; bad.maturity_influence = -0.1; reject_profile(bad);
    bad = forest; bad.maturity_influence = 1.1; reject_profile(bad);
    bad = forest; bad.maturity_influence = std::numeric_limits<double>::quiet_NaN(); reject_profile(bad);
    bad = forest; bad.local_age_span = 0.04; reject_profile(bad);
    bad = forest; bad.local_age_span = 1.01; reject_profile(bad);
    bad = forest; bad.local_age_span = std::numeric_limits<double>::infinity(); reject_profile(bad);
    bad = forest; bad.age_distribution_skew = 0.19; reject_profile(bad);
    bad = forest; bad.age_distribution_skew = 3.01; reject_profile(bad);
    bad = forest; bad.age_distribution_skew = -std::numeric_limits<double>::infinity(); reject_profile(bad);
    bad = forest; bad.height_growth_exponent = 0.24; reject_profile(bad);
    bad = forest; bad.height_growth_exponent = 2.01; reject_profile(bad);
    bad = forest; bad.height_growth_exponent = std::numeric_limits<double>::infinity(); reject_profile(bad);
    bad = forest; bad.girth_growth_exponent = 0.24; reject_profile(bad);
    bad = forest; bad.girth_growth_exponent = 2.01; reject_profile(bad);
    bad = forest; bad.girth_growth_exponent = -std::numeric_limits<double>::infinity(); reject_profile(bad);
    bad = forest; bad.crown_growth_exponent = 0.24; reject_profile(bad);
    bad = forest; bad.crown_growth_exponent = 2.01; reject_profile(bad);
    bad = forest; bad.crown_growth_exponent = std::numeric_limits<double>::infinity(); reject_profile(bad);
    bad = forest; bad.age_band_thresholds[0] = std::numeric_limits<double>::infinity(); reject_profile(bad);
    bad = forest; bad.age_band_thresholds[0] = 0.0; reject_profile(bad);
    bad = forest; bad.age_band_thresholds[3] = 1.0; reject_profile(bad);

    NativeSurfacePropBaselineStream malformed_stream = original;
    auto &entry = const_cast<NativeSurfacePropBaselineEntry &>(malformed_stream.entries()[0]);
    entry.compatibility_draws.pop_back();
    VWB_EXPECT_THROW(NativeSurfaceTreeDefinitionComposerRejected,
        NativeSurfaceTreeDefinitionComposer::create(set, malformed_stream, 0U, world_source(), forest));
    entry = original.entries()[0]; entry.compatibility_draws[0] = std::numeric_limits<float>::infinity();
    VWB_EXPECT_THROW(NativeSurfaceTreeDefinitionComposerRejected,
        NativeSurfaceTreeDefinitionComposer::create(set, malformed_stream, 0U, world_source(), forest));
    entry = original.entries()[0]; entry.outcome = NativeSurfacePropClassificationOutcome::no_feature;
    VWB_EXPECT_THROW(NativeSurfaceTreeDefinitionComposerRejected,
        NativeSurfaceTreeDefinitionComposer::create(set, malformed_stream, 0U, world_source(), forest));
    const NativeSurfacePropBaselineStream conifer_stream = baseline(source, NativeSurfacePropTreeCompatibilityFamily::conifer_22_draw);
    const NativeSurfacePropPlacementSet conifer_set = placements(source, conifer_stream);
    VWB_EXPECT_THROW(NativeSurfaceTreeDefinitionComposerRejected,
        NativeSurfaceTreeDefinitionComposer::create(conifer_set, conifer_stream, 0U, world_source(), forest));
}

VWB_TEST(native_surface_tree_definition_composer_rejects_each_independent_placement_and_replay_mismatch) {
    const NativeSurfacePropAttemptStream source = attempts();
    NativeSurfacePropBaselineStream stream = baseline(source);
    const NativeSurfacePropPlacementSet set = placements(source, stream);
    const NativeSurfaceTreeEcologyProfile forest = profile("forest", "ecological_broadleaf_tree");
    auto &placement = const_cast<NativeSurfacePropPlacementEntry &>(set.entries()[0]);
    auto &entry = const_cast<NativeSurfacePropBaselineEntry &>(stream.entries()[0]);
    const NativeSurfacePropPlacementEntry original_placement = placement;
    const NativeSurfacePropBaselineEntry original_entry = entry;
    const auto rejects = [&]() {
        VWB_EXPECT_THROW(NativeSurfaceTreeDefinitionComposerRejected,
            NativeSurfaceTreeDefinitionComposer::create(set, stream, 0U, world_source(), forest));
    };
    placement.outcome = NativeSurfacePropClassificationOutcome::no_feature; rejects(); placement = original_placement;
    placement.presence = NativeSurfacePropPlacementPresence::absent; rejects(); placement = original_placement;
    placement.ordinal = 1U; rejects(); placement = original_placement;
    entry.ordinal = 1U; rejects(); entry = original_entry;
    placement.durable_id += "x"; rejects(); placement = original_placement;
    placement.cell_x += 1; rejects(); placement = original_placement;
    placement.cell_z += 1; rejects(); placement = original_placement;
    placement.source_decision_digest[0] ^= 0x01U; rejects(); placement = original_placement;
    placement.outcome = NativeSurfacePropClassificationOutcome::conifer_tree; rejects(); placement = original_placement;
    placement.source_decision_digest = {}; entry.source_decision_digest = {}; rejects();
    placement = original_placement; entry = original_entry;
    entry.compatibility_draws[0] = -0.1F; rejects(); entry = original_entry;
    entry.compatibility_draws[0] = 1.0F; rejects(); entry = original_entry;
}

VWB_TEST(native_surface_tree_definition_composer_exercises_fallback_geometry_biome_height_and_all_age_bands) {
    NativeSurfaceTreeEcologyProfile fallback = profile("plains", "ecological_broadleaf_tree");
    fallback.height_min = 0.0; fallback.height_max = 0.0;
    fallback.trunk_radius_min = 0.0; fallback.trunk_radius_max = 0.0;
    fallback.canopy_radius_min = 0.0; fallback.canopy_radius_max = 0.0;
    const NativeTreeDefinition plain = compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, fallback);
    VWB_EXPECT(plain.input().visual_height >= 3.0);
    VWB_EXPECT(plain.input().trunk_radius >= 0.18);
    VWB_EXPECT(plain.input().canopy_radius >= plain.input().trunk_radius * 2.2);
    NativeSurfaceTreeEcologyProfile snow = fallback; snow.source_biome = "snow"; snow.profile_id = "snow";
    NativeSurfaceTreeEcologyProfile tundra = fallback; tundra.source_biome = "tundra"; tundra.profile_id = "tundra";
    VWB_EXPECT(compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, snow).input().visual_height
        > plain.input().visual_height);
    VWB_EXPECT(compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, tundra).input().visual_height
        > plain.input().visual_height);

    NativeSurfaceTreeEcologyProfile flat_age = fallback;
    flat_age.age_min_years = 30.0; flat_age.age_typical_years = 30.0; flat_age.age_max_years = 30.0;
    VWB_EXPECT_EQ(1.0, compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, flat_age).input().ecology.growth_stage);

    NativeSurfaceTreeEcologyProfile repaired_age_window = fallback;
    repaired_age_window.age_min_years = 0.0;
    repaired_age_window.age_typical_years = 0.0;
    repaired_age_window.age_max_years = 1.0;
    const NativeTreeDefinition repaired = compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, repaired_age_window);
    VWB_EXPECT(repaired.input().ecology.age_range_max - repaired.input().ecology.age_range_min >= 0.999999);

    const NativeSurfaceTreeEcologyProfile forest = profile("forest", "ecological_broadleaf_tree");
    const double growth = compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, forest).input().ecology.growth_stage;
    VWB_EXPECT(growth > 0.0 && growth < 1.0);
    const auto with_thresholds = [&](const std::array<double, 4U> &thresholds, const std::string &expected) {
        NativeSurfaceTreeEcologyProfile value = forest; value.age_band_thresholds = thresholds;
        const NativeTreeDefinition tree = compose(NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw, value);
        VWB_EXPECT_EQ(expected, tree.input().age_band);
    };
    const double above = (growth + 1.0) * 0.5;
    with_thresholds({above, (above + 1.0) * 0.5, (above + 3.0) * 0.25, (above + 7.0) * 0.125}, "young");
    with_thresholds({growth * 0.5, above, (above + 1.0) * 0.5, (above + 3.0) * 0.25}, "established");
    with_thresholds({growth * 0.25, growth * 0.5, above, (above + 1.0) * 0.5}, "mature");
    with_thresholds({growth * 0.20, growth * 0.40, growth * 0.60, (growth + 1.0) * 0.5}, "old");
    with_thresholds({growth * 0.20, growth * 0.40, growth * 0.60, growth * 0.80}, "ancient");
}
