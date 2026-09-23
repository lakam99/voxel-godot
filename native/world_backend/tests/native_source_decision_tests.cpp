#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_prop_source_decision_resolver.hpp"

#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

using namespace voxel::world_backend;

namespace {

NativeBiomeEnvironmentCatalog catalog() {
    return NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
}

Sha256Digest world_digest() { Sha256Digest value{}; value[0] = 17U; return value; }

NativeStructureExclusionSnapshot exclusions(bool blocked = false, bool admitted = true) {
    CitadelExclusionSource absent;
    absent.status = CitadelSourceStatus::absent;
    absent.source_key = "world:0,0";
    return NativeStructureExclusionSnapshot::create(world_digest(), 1,
        blocked ? std::vector<StructureExclusionRecord>{{"natural:4,4", {4,4,4,4}}}
                : std::vector<StructureExclusionRecord>{},
        {}, admitted ? std::vector<CitadelExclusionSource>{absent} : std::vector<CitadelExclusionSource>{},
        {{0,0,true}});
}

NativeEffectiveTerrainSource terrain() {
    const auto definition = surface_prop_test_fixture::definition("source-decision");
    return NativeEffectiveTerrainSource(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
}

WorldSourceDefinition flat_definition(double height, const std::string &seed = "source-decision-flat") {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
    descriptor.revisions.terrain_generator_revision = 8U;
    descriptor.revisions.lattice_query_revision = 6U;
    descriptor.revisions.cell_center_query_revision = 7U;
    descriptor.revisions.surface_column_query_revision = 8U;
    descriptor.constants.minimum_surface_meters = height;
    descriptor.constants.maximum_surface_meters = height;
    return WorldSourceDefinition(std::move(descriptor));
}

NativeEffectiveTerrainSource flat_terrain(double height, const std::string &seed = "source-decision-flat") {
    return NativeEffectiveTerrainSource(surface_prop_test_fixture::ready_pin(
        flat_definition(height, seed), {0,0}, surface_prop_test_fixture::empty_deltas()));
}

WorldDeltaPinnedSnapshot raised_column(TerrainBiomeId biome, bool flooded = false,
                                       std::int32_t solid_y = 33) {
    NativeCellStateInput solid;
    solid.cell = {4, solid_y, 4};
    solid.density = 1.0;
    solid.solid = true;
    solid.material = TerrainMaterialId::stone;
    solid.biome = biome;
    solid.block_id = NativeBlockIdentity::create("stone");
    solid.edit_reason = "resolver-coverage";
    solid.generated = false;
    solid.edited = true;
    solid.metadata = NativeValue::object({{"source", NativeValue::string("resolver-coverage")}});
    std::vector<NativeTypedWorldStateRecord> entries{{NativeCellStateNamespace::durable_terrain,
        NativeTypedWorldStatePersistence::durable,
        make_native_cell_state(solid, NativeCellStateNamespace::durable_terrain)}};
    if (flooded) {
        auto fluid = solid;
        fluid.cell.y += 1;
        fluid.density = 0.0;
        fluid.solid = false;
        fluid.material = TerrainMaterialId::water;
        fluid.fluid = TerrainFluidId::water;
        fluid.block_id = NativeBlockIdentity::create("water");
        entries.push_back({NativeCellStateNamespace::durable_terrain,
            NativeTypedWorldStatePersistence::durable,
            make_native_cell_state(fluid, NativeCellStateNamespace::durable_terrain)});
    }
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = flooded ? "resolver:flooded" : "resolver:raised";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create(entries);
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

NativeEffectiveTerrainSource edited_terrain(TerrainBiomeId biome, bool flooded = false,
                                            std::int32_t solid_y = 33, double base_height = 40.0) {
    return NativeEffectiveTerrainSource(surface_prop_test_fixture::ready_pin(
        flat_definition(base_height), {0,0}, raised_column(biome, flooded, solid_y)));
}

std::uint64_t bits(double value) {
    std::uint64_t result = 0;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

} // namespace

VWB_TEST(native_source_decision_resolver_uses_live_pre_roll_admission_order) {
    const auto source = terrain();
    const auto environment = catalog();
    const NativeSurfacePropAttempt attempt{0,4,4,"source-decision:4,4:0"};
    const auto blocked = NativeSurfacePropSourceDecisionResolver::resolve(attempt, source, environment,
        exclusions(true), world_digest(), 1);
    VWB_EXPECT_EQ(NativeSurfacePropAdmission::structure_blocked, blocked.classification.admission);
    VWB_EXPECT(!blocked.has_surface);
    VWB_EXPECT(blocked.classification.source_decision_digest != Sha256Digest{});
    VWB_EXPECT_THROW(NativeSurfacePropSourceDecisionRejected,
        NativeSurfacePropSourceDecisionResolver::resolve(attempt, source, environment,
            exclusions(false, false), world_digest(), 1));
    const auto clear = NativeSurfacePropSourceDecisionResolver::resolve(attempt, source, environment,
        exclusions(), world_digest(), 1);
    VWB_EXPECT(clear.has_surface);
    VWB_EXPECT_EQ(source.sample_surface_prop_spawn({4,4,WorldQueryIntent::gameplay}).height_meters,
        clear.surface.height_meters);
    VWB_EXPECT(clear.classification.source_decision_digest != blocked.classification.source_decision_digest);
    auto wrong_world = world_digest(); wrong_world[0] ^= 1U;
    VWB_EXPECT_THROW(NativeSurfacePropSourceDecisionRejected,
        NativeSurfacePropSourceDecisionResolver::resolve(attempt, source, environment,
            exclusions(), wrong_world, 1));
    VWB_EXPECT_THROW(NativeSurfacePropSourceDecisionRejected,
        NativeSurfacePropSourceDecisionResolver::resolve(attempt, source, environment,
            exclusions(), world_digest(), 2));
}

VWB_TEST(native_source_decision_resolver_computes_float64_godot_cutoffs_and_source_digest) {
    const auto source = terrain();
    const auto environment = catalog();
    const auto exclusion = exclusions();
    NativeSurfacePropAttempt attempt;
    NativeSurfacePropResolvedDecision resolved;
    bool found = false;
    for (std::int32_t z = 0; z < 28 && !found; ++z) {
        for (std::int32_t x = 0; x < 28 && !found; ++x) {
            attempt = {1U,x,z,"source-decision:" + std::to_string(x) + "," + std::to_string(z) + ":1"};
            resolved = NativeSurfacePropSourceDecisionResolver::resolve(attempt, source, environment,
                exclusion, world_digest(), 1);
            found = resolved.classification.admission == NativeSurfacePropAdmission::eligible;
        }
    }
    VWB_EXPECT(found);
    const auto repeat = NativeSurfacePropSourceDecisionResolver::resolve(attempt, source, environment,
        exclusion, world_digest(), 1);
    VWB_EXPECT_EQ(resolved.classification.source_decision_digest, repeat.classification.source_decision_digest);
    VWB_EXPECT_EQ(NativeSurfacePropAdmission::eligible, resolved.classification.admission);
    const auto &profile = environment.profile_for_biome(resolved.biome_id);
    const double height = resolved.surface.height_meters;
    const double rock = profile.rock_base_chance + (height > 42.0 ? 0.12 : 0.0);
    const double tree = height <= 70.0 ? profile.tree_chance : 0.0;
    const double forage = profile.forage_chance;
    const double wildlife = height > 70.0 ? 0.0 : profile.wildlife_chance;
    const auto &policy = resolved.classification.policy;
    VWB_EXPECT_EQ(bits(rock), bits(policy.rock_upper));
    VWB_EXPECT_EQ(bits(rock + tree), bits(policy.tree_upper));
    VWB_EXPECT_EQ(bits(rock + tree + forage), bits(policy.forage_upper));
    VWB_EXPECT_EQ(bits(rock + tree + forage + wildlife), bits(policy.wildlife_upper));
    const auto expected_tree_mode = resolved.biome_id == "taiga" || resolved.biome_id == "snow"
            || resolved.biome_id == "tundra"
        ? NativeSurfacePropTreeReplayMode::legacy_22_draw
        : NativeSurfacePropTreeReplayMode::legacy_36_draw;
    VWB_EXPECT_EQ(expected_tree_mode, policy.tree_replay);
    if (height >= 24.0 && height <= 98.0) {
        VWB_EXPECT_EQ(NativeSurfacePropOrePolicy::eligible, policy.ore_policy);
        double biome_bias = 0.28;
        if (resolved.biome_id == "alpine") biome_bias = 1.0;
        else if (resolved.biome_id == "snow") biome_bias = 0.92;
        else if (resolved.biome_id == "tundra") biome_bias = 0.82;
        else if (resolved.biome_id == "desert") biome_bias = 0.62;
        else if (resolved.biome_id == "savanna") biome_bias = 0.58;
        else if (resolved.biome_id == "taiga") biome_bias = 0.54;
        else if (resolved.biome_id == "plains") biome_bias = 0.38;
        else if (resolved.biome_id == "forest") biome_bias = 0.34;
        else if (resolved.biome_id == "swamp") biome_bias = 0.16;
        const double height_bias = height > 58.0 ? 1.0 : height > 42.0 ? 0.68 : height > 30.0 ? 0.40 : 0.16;
        const double iron = height > 40.0 ? 0.10 * biome_bias * height_bias : 0.015 * biome_bias;
        VWB_EXPECT_EQ(bits(iron), bits(policy.iron_upper));
        VWB_EXPECT_EQ(bits(iron + (0.16 * biome_bias + 0.10 * height_bias)), bits(policy.copper_upper));
    } else VWB_EXPECT_EQ(NativeSurfacePropOrePolicy::none, policy.ore_policy);
    const NativeSurfacePropAttempt changed_id{1U,attempt.cell_x,attempt.cell_z,"source-decision:changed"};
    const auto changed = NativeSurfacePropSourceDecisionResolver::resolve(changed_id, source, environment,
        exclusion, world_digest(), 1);
    VWB_EXPECT(changed.classification.source_decision_digest != resolved.classification.source_decision_digest);
}

VWB_TEST(native_source_decision_resolver_rejects_invalid_attempt_identity) {
    const auto source = terrain();
    const auto environment = catalog();
    const auto exclusion = exclusions();
    VWB_EXPECT_THROW(NativeSurfacePropSourceDecisionRejected,
        NativeSurfacePropSourceDecisionResolver::resolve({0U, 4, 4, ""}, source,
            environment, exclusion, world_digest(), 1));
    VWB_EXPECT_THROW(NativeSurfacePropSourceDecisionRejected,
        NativeSurfacePropSourceDecisionResolver::resolve(
            {NativeSurfacePropAttemptStream::ATTEMPT_COUNT, 4, 4, "invalid-ordinal"}, source,
            environment, exclusion, world_digest(), 1));
}

VWB_TEST(native_source_decision_resolver_applies_height_gate_before_biome_policy) {
    const auto environment = catalog();
    const auto exclusion = exclusions();
    const NativeSurfacePropAttempt attempt{0U, 4, 4, "flat-height:4,4"};
    for (const double height : {11.0, 100.0}) {
        const auto source = flat_terrain(height);
        const auto resolved = NativeSurfacePropSourceDecisionResolver::resolve(attempt, source,
            environment, exclusion, world_digest(), 1);
        VWB_EXPECT(resolved.has_surface);
        VWB_EXPECT(resolved.surface.found);
        VWB_EXPECT_EQ(NativeSurfacePropAdmission::surface_ineligible,
            resolved.classification.admission);
        VWB_EXPECT_EQ(NativeSurfacePropOrePolicy::none,
            resolved.classification.policy.ore_policy);
    }
}

VWB_TEST(native_source_decision_resolver_applies_policy_height_boundaries) {
    const auto environment = catalog();
    const auto exclusion = exclusions();
    const NativeSurfacePropAttempt attempt{0U, 4, 4, "flat-policy:4,4"};
    for (const double height : {20.0, 25.0, 35.0, 45.0, 60.0, 75.0, 90.0}) {
        const auto source = flat_terrain(height);
        const auto resolved = NativeSurfacePropSourceDecisionResolver::resolve(attempt, source,
            environment, exclusion, world_digest(), 1);
        VWB_EXPECT_EQ(NativeSurfacePropAdmission::eligible,
            resolved.classification.admission);
        const auto &profile = environment.profile_for_biome(resolved.biome_id);
        const auto &policy = resolved.classification.policy;
        const double rock = profile.rock_base_chance + (height > 42.0 ? 0.12 : 0.0);
        const double tree = height <= 70.0 ? profile.tree_chance : 0.0;
        const double wildlife = height > 70.0 ? 0.0 : profile.wildlife_chance;
        VWB_EXPECT_EQ(bits(rock), bits(policy.rock_upper));
        VWB_EXPECT_EQ(bits(rock + tree), bits(policy.tree_upper));
        VWB_EXPECT_EQ(bits(rock + tree + profile.forage_chance + wildlife),
            bits(policy.wildlife_upper));
        VWB_EXPECT_EQ(height >= 24.0 ? NativeSurfacePropOrePolicy::eligible
            : NativeSurfacePropOrePolicy::none, policy.ore_policy);
    }
}

VWB_TEST(native_source_decision_resolver_uses_each_regional_biome_policy) {
    const auto environment = catalog();
    const auto exclusion = exclusions();
    const NativeSurfacePropAttempt attempt{0U, 4, 4, "regional-biome:4,4"};
    struct Case { const char *name; double bias; bool found; };
    Case cases[] = {{"plains", 0.38, false}, {"forest", 0.34, false},
        {"swamp", 0.16, false}, {"desert", 0.62, false},
        {"savanna", 0.58, false}, {"snow", 0.92, false},
        {"taiga", 0.54, false}, {"tundra", 0.82, false}};
    for (std::uint32_t i = 0; i < 4096U; ++i) {
        const std::string seed = "source-decision-regional-" + std::to_string(i);
        const std::string biome = BiomeRegionField::sample(
            BiomeRegionField::admit_utf8_seed(seed), {5.4, 5.4}).biome;
        for (Case &target : cases) {
            if (target.found || biome != target.name) continue;
            const auto source = flat_terrain(60.0, seed);
            const auto resolved = NativeSurfacePropSourceDecisionResolver::resolve(attempt, source,
                environment, exclusion, world_digest(), 1);
            VWB_EXPECT_EQ(std::string(target.name), resolved.biome_id);
            VWB_EXPECT_EQ(NativeSurfacePropAdmission::eligible,
                resolved.classification.admission);
            VWB_EXPECT_EQ(bits(0.10 * target.bias),
                bits(resolved.classification.policy.iron_upper));
            target.found = true;
        }
    }
    for (const Case &target : cases) VWB_EXPECT(target.found);
}

VWB_TEST(native_source_decision_resolver_uses_effective_edited_surface) {
    const auto environment = catalog();
    const auto exclusion = exclusions();
    const NativeSurfacePropAttempt attempt{0U, 4, 4, "edited-surface:4,4"};
    const auto alpine = NativeSurfacePropSourceDecisionResolver::resolve(attempt,
        edited_terrain(TerrainBiomeId::alpine), environment, exclusion, world_digest(), 1);
    VWB_EXPECT_EQ(std::string("alpine"), alpine.biome_id);
    VWB_EXPECT_EQ(NativeSurfacePropAdmission::eligible, alpine.classification.admission);
    const auto beach = NativeSurfacePropSourceDecisionResolver::resolve(attempt,
        edited_terrain(TerrainBiomeId::beach), environment, exclusion, world_digest(), 1);
    VWB_EXPECT_EQ(std::string("beach"), beach.biome_id);
    VWB_EXPECT_EQ(NativeSurfacePropAdmission::eligible, beach.classification.admission);
    VWB_EXPECT_EQ(bits(0.10 * 0.28 * 0.68),
        bits(beach.classification.policy.iron_upper));
    const auto air = NativeSurfacePropSourceDecisionResolver::resolve(attempt,
        edited_terrain(TerrainBiomeId::underground_air), environment, exclusion, world_digest(), 1);
    VWB_EXPECT_EQ(std::string("underground_air"), air.biome_id);
    const auto town = NativeSurfacePropSourceDecisionResolver::resolve(attempt,
        edited_terrain(TerrainBiomeId::town), environment, exclusion, world_digest(), 1);
    VWB_EXPECT_EQ(NativeSurfacePropAdmission::town, town.classification.admission);
    const auto flooded = NativeSurfacePropSourceDecisionResolver::resolve(attempt,
        edited_terrain(TerrainBiomeId::plains, true), environment, exclusion, world_digest(), 1);
    VWB_EXPECT(!flooded.surface.found);
    VWB_EXPECT_EQ(NativeSurfacePropAdmission::surface_unavailable,
        flooded.classification.admission);
    const auto low = NativeSurfacePropSourceDecisionResolver::resolve(attempt,
        edited_terrain(TerrainBiomeId::plains, false, 14, 13.0), environment,
        exclusion, world_digest(), 1);
    VWB_EXPECT_EQ(NativeSurfacePropAdmission::eligible, low.classification.admission);
    VWB_EXPECT(low.surface.height_meters < 24.0);
    VWB_EXPECT_EQ(NativeSurfacePropOrePolicy::none, low.classification.policy.ore_policy);
}

VWB_TEST(native_source_decision_resolver_validates_defensive_surface_rules) {
    VWB_EXPECT_EQ(std::string("underground"), std::string(
        NativeSurfacePropSourceDecisionResolver::biome_name(TerrainBiomeId::underground)));
    VWB_EXPECT_EQ(std::string("deep_underground"), std::string(
        NativeSurfacePropSourceDecisionResolver::biome_name(TerrainBiomeId::deep_underground)));
    VWB_EXPECT_THROW(NativeSurfacePropSourceDecisionRejected,
        NativeSurfacePropSourceDecisionResolver::biome_name(static_cast<TerrainBiomeId>(255)));
    NativeSurfacePropSourceDecisionResolver::require_finite_surface_height(40.0);
    VWB_EXPECT_THROW(NativeSurfacePropSourceDecisionRejected,
        NativeSurfacePropSourceDecisionResolver::require_finite_surface_height(
            std::numeric_limits<double>::quiet_NaN()));
    VWB_EXPECT_THROW(NativeSurfacePropSourceDecisionRejected,
        NativeSurfacePropSourceDecisionResolver::require_finite_surface_height(
            std::numeric_limits<double>::infinity()));
}
