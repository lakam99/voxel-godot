#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_rock_ordered_composer.hpp"

#include <cmath>
#include <limits>
#include <utility>

using namespace voxel::world_backend;

namespace {

Sha256Digest world_digest() { Sha256Digest d{}; d[0] = 37U; return d; }

NativeStructureExclusionSnapshot exclusions(const std::string &source_key = "world:0,0") {
    CitadelExclusionSource absent;
    absent.status = CitadelSourceStatus::absent;
    absent.source_key = source_key;
    return NativeStructureExclusionSnapshot::create(world_digest(), 1U, {}, {}, {absent}, {{0,0,true}});
}

NativeWildlifePresentationReceipt animal(NativeWildlifeVariant variant, const char *asset) {
    NativeWildlifePresentationReceipt r;
    r.schema_revision = 1U; r.asset_catalog_digest.fill(1U);
    r.variant = variant; r.path = NativeWildlifePresentationPath::animated_playable;
    r.asset_id = asset; r.animation_clip_id = asset;
    return r;
}

NativeWildlifePresentationCatalog wildlife() {
    return NativeWildlifePresentationCatalog::create({
        animal(NativeWildlifeVariant::boar, "boar_idle_walk"),
        animal(NativeWildlifeVariant::deer, "deer_idle_walk"),
        animal(NativeWildlifeVariant::hare, "hare_idle_walk")});
}

NativeSurfacePropSourceOrderedStream stream(const NativeEffectiveTerrainSource &terrain,
    const NativeFeatureDeltaSnapshot &removed = NativeFeatureDeltaSnapshot::create({}, {}),
    const std::string &exclusion_key = "world:0,0", bool force_rock = true) {
    auto profiles = tests::godot_oracle_environment_profiles();
    if (force_rock) for (auto &profile : profiles) profile.rock_base_chance = 1.0;
    return NativeSurfacePropSourceOrderedStream::create(terrain.pin().definition().raw_terrain_seed(),
        0, 0, world_digest(), 1U, terrain,
        NativeBiomeEnvironmentCatalog::create(std::move(profiles)), exclusions(exclusion_key), removed, wildlife());
}

std::uint32_t first_rock(const NativeSurfacePropSourceOrderedStream &ordered) {
    for (std::uint32_t i = 0U; i < ordered.attempts().size(); ++i)
        if (ordered.attempts()[i].outcome == NativeSurfacePropClassificationOutcome::ordinary_rock) return i;
    throw std::runtime_error("test seed did not produce an ordinary rock");
}

NativeSurfaceRockProfile profile_for(const NativeEffectiveTerrainSource &terrain,
    const NativeSurfacePropPlacementEntry &placement) {
    const auto x = native_surface_rock_visual_cell(placement.world_anchor.x,
        terrain.pin().definition().constants().cell_size_meters);
    const auto z = native_surface_rock_visual_cell(placement.world_anchor.z,
        terrain.pin().definition().constants().cell_size_meters);
    NativeSurfaceRockProfile p;
    p.schema_revision = 1U; p.profile_revision = 3U; p.source_profile_digest.fill(9U);
    p.source_biome = NativeSurfacePropSourceDecisionResolver::biome_name(
        terrain.sample_surface_biome({x,z,WorldQueryIntent::gameplay}));
    p.profile_id = p.source_biome + "_rock_profile";
    return p;
}

NativeSurfaceRockPresentationReceipt presentation(const NativeSurfaceRockProfile &profile) {
    NativeSurfaceRockPresentationReceipt p;
    p.schema_revision = 1U; p.asset_catalog_digest.fill(7U);
    p.source_profile_digest = profile.source_profile_digest;
    p.source_biome = profile.source_biome; p.profile_id = profile.profile_id;
    p.asset_id = "rock_01";
    return p;
}

} // namespace

VWB_TEST(native_ordered_rock_visual_cell_rounds_float32_world_coordinates) {
    VWB_EXPECT_EQ(0, native_surface_rock_visual_cell(0.0F, 1.35));
    VWB_EXPECT_EQ(1, native_surface_rock_visual_cell(0.675F, 1.35));
    VWB_EXPECT_EQ(-1, native_surface_rock_visual_cell(-0.675F, 1.35));
    VWB_EXPECT_EQ(0, native_surface_rock_visual_cell(std::nextafter(0.675F, 0.0F), 1.35));
    VWB_EXPECT_EQ(0, native_surface_rock_visual_cell(std::nextafter(-0.675F, 0.0F), 1.35));
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        native_surface_rock_visual_cell(std::numeric_limits<float>::infinity(), 1.35));
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        native_surface_rock_visual_cell(1.0F, 0.0));
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        native_surface_rock_visual_cell(1.0F, std::numeric_limits<double>::infinity()));
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        native_surface_rock_visual_cell(std::numeric_limits<float>::max(), 1.35));
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        native_surface_rock_visual_cell(1.0F, std::numeric_limits<double>::min()));
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        native_surface_rock_visual_cell(-std::numeric_limits<float>::max(), 1.35));
}

VWB_TEST(native_ordered_rock_rejects_torn_provenance_and_receipts) {
    const auto definition = surface_prop_test_fixture::definition("ordered-rock-provenance");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto ordered = stream(terrain);
    const auto placements = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
    const auto ordinal = first_rock(ordered);
    const auto profile = profile_for(terrain, placements.entries()[ordinal]);
    const auto receipt = presentation(profile);
    const auto reject_with = [&](const NativeSurfaceRockProfile &p,
        const NativeSurfaceRockPresentationReceipt &r) {
        VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
            NativeSurfaceRockOrderedComposer::create(ordered, placements, ordinal, terrain, p, r));
    };
    auto p = profile; p.schema_revision = 0U; reject_with(p, receipt);
    p = profile; p.profile_revision = 0U; reject_with(p, receipt);
    p = profile; p.source_profile_digest = {}; reject_with(p, receipt);
    p = profile; p.source_biome.clear(); reject_with(p, receipt);
    p = profile; p.profile_id.clear(); reject_with(p, receipt);
    auto r = receipt; r.schema_revision = 0U; reject_with(profile, r);
    r = receipt; r.asset_catalog_digest = {}; reject_with(profile, r);
    r = receipt; r.source_biome = "other"; reject_with(profile, r);
    r = receipt; r.profile_id = "other"; reject_with(profile, r);
    r = receipt; r.asset_id.clear(); reject_with(profile, r);

    const auto tombstoned = stream(terrain, NativeFeatureDeltaSnapshot::create(
        {{ordered.attempts()[0].attempt.durable_id}}, {}));
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        NativeSurfaceRockOrderedComposer::create(tombstoned, placements, ordinal,
            terrain, profile, receipt));
    const auto alternate_exclusions = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}),
        "world:0,0:alternate-absent");
    VWB_EXPECT_EQ(ordered.final_rng_state(), alternate_exclusions.final_rng_state());
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        NativeSurfaceRockOrderedComposer::create(alternate_exclusions, placements, ordinal,
            terrain, profile, receipt));
    const auto stale_definition = surface_prop_test_fixture::definition("stale-rock-provenance");
    const NativeEffectiveTerrainSource stale(surface_prop_test_fixture::ready_pin(
        stale_definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        NativeSurfaceRockOrderedComposer::create(ordered, placements, ordinal,
            stale, profile, receipt));
    const auto natural = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}), "world:0,0", false);
    const auto natural_placements = NativeSurfacePropOrderedPlacement::create(natural, terrain);
    std::uint32_t nonrock = 28U;
    for (std::uint32_t i = 0U; i < natural.attempts().size(); ++i)
        if (natural.attempts()[i].outcome != NativeSurfacePropClassificationOutcome::ordinary_rock) {
            nonrock = i; break;
        }
    VWB_EXPECT(nonrock < 28U);
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        NativeSurfaceRockOrderedComposer::create(natural, natural_placements, nonrock,
            terrain, profile, receipt));
}

VWB_TEST(native_ordered_rock_binds_visual_biome_receipts_and_six_draw_geometry) {
    const auto definition = surface_prop_test_fixture::definition("ordered-rock");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto ordered = stream(terrain);
    const auto placements = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
    const auto ordinal = first_rock(ordered);
    const auto &placement = placements.entries()[ordinal];
    const auto profile = profile_for(terrain, placement);
    const auto receipt = presentation(profile);
    const auto rock = NativeSurfaceRockOrderedComposer::create(ordered, placements, ordinal,
        terrain, profile, receipt);
    const auto &draw = ordered.attempts()[ordinal].compatibility_draws;
    VWB_EXPECT_EQ(6U, draw.size());
    VWB_EXPECT_EQ(placement.durable_id, rock.input().durable_feature_id);
    VWB_EXPECT_EQ(profile.source_biome, rock.input().source_biome);
    VWB_EXPECT_EQ(placement.world_anchor.x, rock.input().position.x);
    VWB_EXPECT_EQ(placement.world_anchor.z, rock.input().position.z);
    VWB_EXPECT_EQ(static_cast<double>(draw[0]) * 6.28318530717958647692, rock.input().rotation_y);
    VWB_EXPECT_EQ(0.55 + static_cast<double>(draw[1]) * 0.7, rock.input().visual_radius);
    VWB_EXPECT_EQ(0.75 + static_cast<double>(draw[2]) * 0.8, rock.input().visual_height_factor);
    VWB_EXPECT_EQ(static_cast<float>(1.15 + static_cast<double>(draw[3]) * 0.6), rock.input().visual_scale_x);
    VWB_EXPECT_EQ(static_cast<float>(0.58 + static_cast<double>(draw[4]) * 0.72), rock.input().visual_scale_y);
    VWB_EXPECT_EQ(static_cast<float>(1.0 + static_cast<double>(draw[5]) * 0.5), rock.input().visual_scale_z);
    auto changed_receipt = receipt; changed_receipt.asset_id = "rock_02";
    const auto changed = NativeSurfaceRockOrderedComposer::create(ordered, placements, ordinal,
        terrain, profile, changed_receipt);
    VWB_EXPECT(rock.content_digest() != changed.content_digest());
    auto mismatch = profile; mismatch.source_biome = profile.source_biome == "forest" ? "plains" : "forest";
    auto matching_presentation = presentation(mismatch);
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        NativeSurfaceRockOrderedComposer::create(ordered, placements, ordinal,
            terrain, mismatch, matching_presentation));
    auto bad_receipt = receipt; bad_receipt.source_profile_digest = {};
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        NativeSurfaceRockOrderedComposer::create(ordered, placements, ordinal,
            terrain, profile, bad_receipt));
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedComposerRejected,
        NativeSurfaceRockOrderedComposer::create(ordered, placements, 28U,
            terrain, profile, receipt));
}
