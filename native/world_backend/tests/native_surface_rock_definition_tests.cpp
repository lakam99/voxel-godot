#include "test_harness.hpp"

#include "../core/native_surface_rock_definition.hpp"
#include "../core/godot_pcg_compat.hpp"
#include "native_surface_prop_test_fixture.hpp"

#include <array>
#include <cmath>
#include <cstring>
#include <limits>

using namespace voxel::world_backend;

namespace {

NativeSurfacePropAttemptStream attempts() {
    return NativeSurfacePropAttemptStream::create(admit_raw_terrain_seed("rock-composer"), -2, 3);
}

WorldSourceDefinition source_definition() {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("rock-composer");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("rock-composer");
    descriptor.revisions.terrain_generator_revision = 3U;
    descriptor.revisions.lattice_query_revision = 5U;
    return WorldSourceDefinition(std::move(descriptor));
}

NativeSurfacePropBaselineInput input_for(const NativeSurfacePropAttempt &attempt) {
    NativeSurfacePropBaselineInput input;
    input.classification.ordinal = attempt.ordinal;
    input.classification.cell_x = attempt.cell_x;
    input.classification.cell_z = attempt.cell_z;
    input.classification.source_decision_digest.fill(static_cast<std::uint8_t>(attempt.ordinal + 1U));
    input.classification.admission = NativeSurfacePropAdmission::eligible;
    input.classification.policy.rock_upper = 1.0F;
    input.classification.policy.tree_upper = 1.0F;
    input.classification.policy.forage_upper = 1.0F;
    input.classification.policy.wildlife_upper = 1.0F;
    input.classification.policy.tree_family = NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw;
    return input;
}

NativeSurfacePropBaselineStream baseline(const NativeSurfacePropAttemptStream &source) {
    std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> inputs{};
    for (std::size_t index = 0U; index < inputs.size(); ++index) inputs[index] = input_for(source.attempts()[index]);
    return NativeSurfacePropBaselineStream::create(source, inputs);
}

NativeSurfacePropPlacementSet placements(const NativeSurfacePropAttemptStream &source,
    const NativeSurfacePropBaselineStream &stream, const WorldSourceDefinition &world) {
    NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        world, {-1, 0}, surface_prop_test_fixture::empty_deltas()));
    return NativeSurfacePropPlacementSet::create(
        source, stream, surface_prop_test_fixture::receipt(terrain.pin()), terrain);
}

NativeSurfaceRockProfile profile() {
    NativeSurfaceRockProfile result;
    result.schema_revision = 1U; result.profile_revision = 2U; result.source_profile_digest.fill(9U);
    result.source_biome = "forest"; result.profile_id = "forest_profile";
    return result;
}

NativeSurfaceRockDefinition compose(const std::uint32_t ordinal = 0U) {
    const NativeSurfacePropAttemptStream source = attempts();
    const NativeSurfacePropBaselineStream stream = baseline(source);
    const WorldSourceDefinition world = source_definition();
    return NativeSurfaceRockDefinitionComposer::create(placements(source, stream, world), stream, ordinal, world, profile());
}

std::uint32_t bits32(const float value) {
    std::uint32_t result = 0U;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

} // namespace

VWB_TEST(native_surface_rock_definition_composer_binds_exact_shared_recipe_geometry) {
    const NativeSurfacePropAttemptStream source = attempts();
    const NativeSurfacePropBaselineStream stream = baseline(source);
    const WorldSourceDefinition world = source_definition();
    const NativeSurfacePropPlacementSet set = placements(source, stream, world);
    const NativeSurfaceRockDefinition rock = NativeSurfaceRockDefinitionComposer::create(set, stream, 0U, world, profile());
    const NativeSurfaceRockDefinitionInput &input = rock.input();
    const NativeSurfacePropBaselineEntry &entry = stream.entries()[0];
    const NativeSurfacePropPlacementEntry &placement = set.entries()[0];
    VWB_EXPECT_EQ(std::string("native_surface_rock_recipe"), input.producer_key);
    VWB_EXPECT_EQ(placement.durable_id, input.durable_feature_id);
    VWB_EXPECT_EQ(std::string("forest"), input.source_biome);
    VWB_EXPECT_EQ(placement.world_anchor.x, input.position.x);
    VWB_EXPECT_EQ(placement.world_anchor.y, input.position.y);
    VWB_EXPECT_EQ(placement.world_anchor.z, input.position.z);
    VWB_EXPECT_EQ(static_cast<double>(entry.compatibility_draws[0]) * 6.28318530717958647692, input.rotation_y);
    VWB_EXPECT_EQ(0.55 + static_cast<double>(entry.compatibility_draws[1]) * 0.7, input.visual_radius);
    VWB_EXPECT_EQ(0.75 + static_cast<double>(entry.compatibility_draws[2]) * 0.8, input.visual_height_factor);
    VWB_EXPECT_EQ(static_cast<float>(1.15 + static_cast<double>(entry.compatibility_draws[3]) * 0.6), input.visual_scale_x);
    VWB_EXPECT_EQ(static_cast<float>(0.58 + static_cast<double>(entry.compatibility_draws[4]) * 0.72), input.visual_scale_y);
    VWB_EXPECT_EQ(static_cast<float>(1.0 + static_cast<double>(entry.compatibility_draws[5]) * 0.5), input.visual_scale_z);
    VWB_EXPECT_EQ(static_cast<float>(input.visual_radius * 1.05), input.collision.radius);
    VWB_EXPECT_EQ(static_cast<float>(input.visual_radius * 0.42), input.collision.center_y);
}

VWB_TEST(native_surface_rock_definition_has_stable_digest_and_profile_identity) {
    const NativeSurfaceRockDefinition first = compose(3U);
    const NativeSurfaceRockDefinition second = compose(3U);
    VWB_EXPECT_EQ(first, second);
    VWB_EXPECT_EQ(first.canonical_binary(), second.canonical_binary());
    VWB_EXPECT_EQ(first.content_digest(), second.content_digest());
    const NativeSurfacePropAttemptStream source = attempts(); const NativeSurfacePropBaselineStream stream = baseline(source);
    const WorldSourceDefinition world = source_definition(); const NativeSurfacePropPlacementSet set = placements(source, stream, world);
    NativeSurfaceRockProfile changed = profile(); changed.profile_revision += 1U;
    const NativeSurfaceRockDefinition revised = NativeSurfaceRockDefinitionComposer::create(set, stream, 3U, world, changed);
    VWB_EXPECT(first.content_digest() != revised.content_digest());
}

VWB_TEST(native_surface_rock_definition_rejects_invalid_canonical_values) {
    NativeSurfaceRockDefinitionInput input = compose().input();
    const auto rejects = [&](NativeSurfaceRockDefinitionInput value) {
        VWB_EXPECT_THROW(NativeSurfaceRockDefinitionRejected, NativeSurfaceRockDefinition::create(std::move(value)));
    };
    input.schema_revision = 0U; rejects(input); input = compose().input();
    input.producer_revision = 0U; rejects(input); input = compose().input();
    input.source_recipe_digest = {}; rejects(input); input = compose().input();
    input.producer_key.clear(); rejects(input); input = compose().input();
    input.durable_feature_id.clear(); rejects(input); input = compose().input();
    input.source_biome.clear(); rejects(input); input = compose().input();
    input.profile_id.clear(); rejects(input); input = compose().input();
    input.position.x = std::numeric_limits<float>::quiet_NaN(); rejects(input); input = compose().input();
    input.position.y = std::numeric_limits<float>::quiet_NaN(); rejects(input); input = compose().input();
    input.position.z = std::numeric_limits<float>::quiet_NaN(); rejects(input); input = compose().input();
    input.rotation_y = std::numeric_limits<float>::infinity(); rejects(input); input = compose().input();
    input.visual_radius = std::numeric_limits<double>::infinity(); rejects(input); input = compose().input();
    input.visual_height_factor = std::numeric_limits<double>::quiet_NaN(); rejects(input); input = compose().input();
    input.visual_scale_x = std::numeric_limits<float>::infinity(); rejects(input); input = compose().input();
    input.visual_scale_y = std::numeric_limits<float>::quiet_NaN(); rejects(input); input = compose().input();
    input.visual_scale_z = std::numeric_limits<float>::infinity(); rejects(input); input = compose().input();
    input.collision.radius = std::numeric_limits<float>::quiet_NaN(); rejects(input); input = compose().input();
    input.collision.center_y = std::numeric_limits<float>::infinity(); rejects(input); input = compose().input();
    input.visual_radius = 0.54F; rejects(input); input = compose().input();
    input.visual_radius = 1.25F; rejects(input); input = compose().input();
    input.visual_height_factor = 0.74F; rejects(input); input = compose().input();
    input.visual_height_factor = 1.55; rejects(input); input = compose().input();
    input.visual_scale_x = 1.14F; rejects(input); input = compose().input();
    input.visual_scale_x = 1.76F; rejects(input); input = compose().input();
    input.visual_scale_y = 0.57F; rejects(input); input = compose().input();
    input.visual_scale_y = 1.31F; rejects(input); input = compose().input();
    input.visual_scale_z = 0.99F; rejects(input); input = compose().input();
    input.visual_scale_z = 1.51F; rejects(input); input = compose().input();
    input.collision.radius += 0.01F; rejects(input); input = compose().input();
    input.collision.center_y += 0.01F; rejects(input);
    input = compose().input(); input.producer_key.assign(4097U, 'x'); rejects(input);
    input = compose().input(); input.durable_feature_id.assign(4097U, 'x'); rejects(input);
    input = compose().input(); input.source_biome.assign(4097U, 'x'); rejects(input);
    input = compose().input(); input.profile_id.assign(4097U, 'x'); rejects(input);
    VWB_EXPECT_THROW(NativeSurfaceRockDefinitionRejected,
        NativeSurfaceRockDefinition::create(compose().input(), NativeSurfaceRockDefinitionLimits{4096U, 1U}));
}

VWB_TEST(native_surface_rock_definition_matches_godot_seed_zero_physical_oracle) {
    GodotPcg32 rng(0U);
    const float rotation_draw = rng.randf();
    const float radius_draw = rng.randf();
    const float height_draw = rng.randf();
    const float scale_x_draw = rng.randf();
    const float scale_y_draw = rng.randf();
    const float scale_z_draw = rng.randf();
    NativeSurfaceRockDefinitionInput input = compose().input();
    input.rotation_y = static_cast<double>(rotation_draw) * 6.28318530717958647692;
    input.visual_radius = 0.55 + static_cast<double>(radius_draw) * 0.7;
    input.visual_height_factor = 0.75 + static_cast<double>(height_draw) * 0.8;
    input.visual_scale_x = static_cast<float>(1.15 + static_cast<double>(scale_x_draw) * 0.6);
    input.visual_scale_y = static_cast<float>(0.58 + static_cast<double>(scale_y_draw) * 0.72);
    input.visual_scale_z = static_cast<float>(1.0 + static_cast<double>(scale_z_draw) * 0.5);
    input.collision = {static_cast<float>(input.visual_radius * 1.05), static_cast<float>(input.visual_radius * 0.42)};
    const NativeSurfaceRockDefinition rock = NativeSurfaceRockDefinition::create(input);
    VWB_EXPECT_EQ(0x3fa2ad3aU, bits32(static_cast<float>(rock.input().rotation_y)));
    VWB_EXPECT_EQ(0x3f2b6d79U, bits32(rock.input().collision.radius));
    VWB_EXPECT_EQ(0x3e892461U, bits32(rock.input().collision.center_y));
    VWB_EXPECT_EQ(0x3fa02b3eU, bits32(rock.input().visual_scale_x));
}

VWB_TEST(native_surface_rock_definition_equality_tracks_every_canonical_field) {
    const NativeSurfaceRockDefinition original = compose();
    const NativeSurfaceRockDefinitionInput base = original.input();
    const auto differs = [&](const NativeSurfaceRockDefinitionInput &value) {
        VWB_EXPECT(!(base == value));
    };
    NativeSurfaceRockDefinitionInput value = base;
    value.schema_revision += 1U; differs(value); value = base;
    value.producer_key += "_v2"; differs(value); value = base;
    value.producer_revision += 1U; differs(value); value = base;
    value.source_recipe_digest[0] ^= 1U; differs(value); value = base;
    value.durable_feature_id += "_v2"; differs(value); value = base;
    value.source_biome += "_v2"; differs(value); value = base;
    value.profile_id += "_v2"; differs(value); value = base;
    value.position.x += 1.0F; differs(value); value = base;
    value.position.y += 1.0F; differs(value); value = base;
    value.position.z += 1.0F; differs(value); value = base;
    value.rotation_y += 0.1; differs(value); value = base;
    value.visual_radius += 0.01; differs(value); value = base;
    value.visual_height_factor += 0.01; differs(value); value = base;
    value.visual_scale_x += 0.01F; differs(value); value = base;
    value.visual_scale_y += 0.01F; differs(value); value = base;
    value.visual_scale_z += 0.01F; differs(value); value = base;
    value.collision.radius += 0.01F; differs(value); value = base;
    value.collision.center_y += 0.01F; differs(value);

    NativeSurfaceRockDefinitionInput revised = base;
    revised.profile_id += "_v2";
    const NativeSurfaceRockDefinition other = NativeSurfaceRockDefinition::create(std::move(revised));
    VWB_EXPECT(original != other);
    VWB_EXPECT(!(other == original));
    VWB_EXPECT(original == original);
}

VWB_TEST(native_surface_rock_definition_composer_rejects_invalid_profile_and_source) {
    const NativeSurfacePropAttemptStream source = attempts();
    const NativeSurfacePropBaselineStream stream = baseline(source);
    const WorldSourceDefinition world = source_definition();
    const NativeSurfacePropPlacementSet set = placements(source, stream, world);
    const auto rejects = [&](NativeSurfaceRockProfile value) {
        VWB_EXPECT_THROW(NativeSurfaceRockDefinitionComposerRejected,
            NativeSurfaceRockDefinitionComposer::create(set, stream, 0U, world, value));
    };
    NativeSurfaceRockProfile value = profile();
    value.schema_revision = 0U; rejects(value); value = profile();
    value.profile_revision = 0U; rejects(value); value = profile();
    value.source_profile_digest = {}; rejects(value); value = profile();
    value.source_biome.clear(); rejects(value); value = profile();
    value.profile_id.clear(); rejects(value);
    value = profile(); value.profile_id.assign(4097U, 'x'); rejects(value);
    VWB_EXPECT_THROW(NativeSurfaceRockDefinitionComposerRejected,
        NativeSurfaceRockDefinitionComposer::create(set, stream,
            NativeSurfacePropAttemptStream::ATTEMPT_COUNT, world, profile()));
    WorldSourceDescriptor altered;
    altered.raw_terrain_seed = admit_raw_terrain_seed("rock-composer");
    altered.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("rock-composer");
    altered.revisions.terrain_generator_revision = 4U;
    altered.revisions.lattice_query_revision = 5U;
    const WorldSourceDefinition wrong_world(std::move(altered));
    VWB_EXPECT_THROW(NativeSurfaceRockDefinitionComposerRejected,
        NativeSurfaceRockDefinitionComposer::create(set, stream, 0U, wrong_world, profile()));
}

VWB_TEST(native_surface_rock_definition_composer_requires_ordinary_rock_placement_and_matching_baseline) {
    const NativeSurfacePropAttemptStream source = attempts();
    const NativeSurfacePropBaselineStream rock_stream = baseline(source);
    const WorldSourceDefinition world = source_definition();
    const NativeSurfacePropPlacementSet rock_set = placements(source, rock_stream, world);

    std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> inputs{};
    for (std::size_t index = 0U; index < inputs.size(); ++index) {
        inputs[index] = input_for(source.attempts()[index]);
    }
    inputs[0].classification.policy.rock_upper = 0.0F;
    inputs[0].classification.policy.tree_upper = 0.0F;
    inputs[0].classification.policy.forage_upper = 0.0F;
    inputs[0].classification.policy.wildlife_upper = 0.0F;
    const NativeSurfacePropBaselineStream no_rock_stream = NativeSurfacePropBaselineStream::create(source, inputs);
    const NativeSurfacePropPlacementSet no_rock_set = placements(source, no_rock_stream, world);
    VWB_EXPECT(no_rock_set.entries()[0].outcome != NativeSurfacePropClassificationOutcome::ordinary_rock);
    VWB_EXPECT_THROW(NativeSurfaceRockDefinitionComposerRejected,
        NativeSurfaceRockDefinitionComposer::create(no_rock_set, no_rock_stream, 0U, world, profile()));
    VWB_EXPECT_THROW(NativeSurfaceRockDefinitionComposerRejected,
        NativeSurfaceRockDefinitionComposer::create(rock_set, no_rock_stream, 0U, world, profile()));

    std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> changed_inputs{};
    for (std::size_t index = 0U; index < changed_inputs.size(); ++index) {
        changed_inputs[index] = input_for(source.attempts()[index]);
    }
    changed_inputs[0].classification.source_decision_digest[0] ^= 1U;
    const NativeSurfacePropBaselineStream changed_decision_stream =
        NativeSurfacePropBaselineStream::create(source, changed_inputs);
    VWB_EXPECT_THROW(NativeSurfaceRockDefinitionComposerRejected,
        NativeSurfaceRockDefinitionComposer::create(rock_set, changed_decision_stream, 0U, world, profile()));

    bool tested_cell_x = false;
    bool tested_cell_z = false;
    for (std::uint32_t salt = 0U; salt < 512U && (!tested_cell_x || !tested_cell_z); ++salt) {
        const NativeSurfacePropAttemptStream alternate = NativeSurfacePropAttemptStream::create(
            admit_raw_terrain_seed("rock-composer-alternate-" + std::to_string(salt)), -2, 3);
        const NativeSurfacePropAttempt &first = alternate.attempts()[0];
        const NativeSurfacePropPlacementEntry &placed = rock_set.entries()[0];
        if (first.cell_x != placed.cell_x && !tested_cell_x) {
            const NativeSurfacePropBaselineStream alternate_stream = baseline(alternate);
            VWB_EXPECT_THROW(NativeSurfaceRockDefinitionComposerRejected,
                NativeSurfaceRockDefinitionComposer::create(rock_set, alternate_stream, 0U, world, profile()));
            tested_cell_x = true;
        }
        if (first.cell_x == placed.cell_x && first.cell_z != placed.cell_z && !tested_cell_z) {
            const NativeSurfacePropBaselineStream alternate_stream = baseline(alternate);
            VWB_EXPECT_THROW(NativeSurfaceRockDefinitionComposerRejected,
                NativeSurfaceRockDefinitionComposer::create(rock_set, alternate_stream, 0U, world, profile()));
            tested_cell_z = true;
        }
    }
    VWB_EXPECT(tested_cell_x);
    VWB_EXPECT(tested_cell_z);

    const NativeSurfacePropAttemptStream shifted = NativeSurfacePropAttemptStream::create(
        admit_raw_terrain_seed("rock-composer"), -1, 3);
    const NativeSurfacePropBaselineStream shifted_stream = baseline(shifted);
    VWB_EXPECT_THROW(NativeSurfaceRockDefinitionComposerRejected,
        NativeSurfaceRockDefinitionComposer::create(rock_set, shifted_stream, 0U, world, profile()));
}
