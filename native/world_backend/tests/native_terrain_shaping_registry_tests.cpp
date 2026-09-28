#include "test_harness.hpp"

#include "../core/native_terrain_shaping_registry.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

WorldSourceDefinition definition_for(const std::string &seed = "atlas-1492") {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
    descriptor.revisions.terrain_generator_revision = 8;
    descriptor.revisions.lattice_query_revision = 6;
    descriptor.revisions.cell_center_query_revision = 7;
    descriptor.revisions.surface_column_query_revision = 8;
    return WorldSourceDefinition(std::move(descriptor));
}

NativeSiteSourcePolicy policy_for() {
    NativeSiteSourcePolicy policy;
    policy.engine_version_utf8 = "4.6.1.stable.official.14d19694e";
    policy.ordinary_region_cells = 140;
    policy.ordinary_spawn_chance = 0.08;
    return policy;
}

NativeSiteTerrainProfile profile_for(
    const NativeSiteSourceCandidate &candidate,
    const std::string &seed = "atlas-1492") {
    NativeSiteTerrainProfile profile;
    profile.world_seed_utf8 = seed; profile.site_id = candidate.site_id;
    profile.source_signature = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    profile.core_cells = {candidate.center_x - 1, candidate.center_z - 1, 3, 3};
    profile.envelope_cells = {candidate.center_x - 2, candidate.center_z - 2, 5, 5};
    profile.reservation_cells = profile.core_cells;
    profile.origin = {
        static_cast<float>(static_cast<double>(candidate.center_x) * profile.cell_size_meters),
        12.0F,
        static_cast<float>(static_cast<double>(candidate.center_z) * profile.cell_size_meters)};
    profile.level_meters = 12.0; profile.apron_cells = 1;
    profile.support_mask.assign(25, 0); profile.support_mask[12] = 1;
    profile.distance_cells.assign(25, 1.0F); profile.distance_cells[12] = 0.0F;
    profile.ground_root_points.assign(4, profile.origin);
    return profile;
}

NativeHorizontalRect source_reservation_for(const NativeSiteSourceCandidate &candidate) {
    return {candidate.center_x - 3, candidate.center_z - 3, 7, 7};
}

NativeHorizontalRect merged_source_reservation_for(const NativeSiteTerrainProfile &profile) {
    const std::int64_t low_x = std::min<std::int64_t>(static_cast<std::int64_t>(profile.envelope_cells.x) - 1, profile.reservation_cells.x);
    const std::int64_t low_z = std::min<std::int64_t>(static_cast<std::int64_t>(profile.envelope_cells.z) - 1, profile.reservation_cells.z);
    const std::int64_t high_x = std::max(static_cast<std::int64_t>(profile.envelope_cells.x) + profile.envelope_cells.width + 1,
        static_cast<std::int64_t>(profile.reservation_cells.x) + profile.reservation_cells.width);
    const std::int64_t high_z = std::max(static_cast<std::int64_t>(profile.envelope_cells.z) + profile.envelope_cells.depth + 1,
        static_cast<std::int64_t>(profile.reservation_cells.z) + profile.reservation_cells.depth);
    return {static_cast<std::int32_t>(low_x), static_cast<std::int32_t>(low_z),
        static_cast<std::int32_t>(high_x - low_x), static_cast<std::int32_t>(high_z - low_z)};
}

NativeSiteSourceResolution absent_resolution(
    const NativeTerrainShapingRegistry &registry,
    const NativeSiteSourceRegionKey region,
    const char key = 'a') {
    NativeSiteSourceResolution value; value.region = region;
    value.kind = NativeSiteSourceResolutionKind::absent;
    value.request_identity = registry.source_request_identity(region);
    value.worker_source_key.assign(64, key); value.reason_code = "ordinary_structure_overlap";
    return value;
}

NativeSiteSourceResolution failed_resolution(
    const NativeTerrainShapingRegistry &registry,
    const NativeSiteSourceRegionKey region,
    const char key = 'b') {
    NativeSiteSourceResolution value = absent_resolution(registry, region, key);
    value.kind = NativeSiteSourceResolutionKind::failed; value.reason_code = "source_preparation_failed";
    return value;
}

NativeSiteSourceResolution prepared_resolution(
    const NativeTerrainShapingRegistry &registry,
    const NativeSiteSourceRegionKey region,
    NativeAdmittedSiteTerrainProfileHandle profile,
    const char key = 'c') {
    const auto candidate = native_site_source_candidate_for_region(registry.definition(), region);
    NativeSiteSourceResolution value; value.region = region;
    value.kind = NativeSiteSourceResolutionKind::prepared;
    value.request_identity = registry.source_request_identity(region);
    value.worker_source_key.assign(64, key); value.profile = std::move(profile);
    value.manifest_source_signature = value.profile->source_signature();
    value.source_reservation_cells = source_reservation_for(*candidate);
    return value;
}

NativeTerrainShapingRegistryRejectReason apply_rejection(
    NativeTerrainShapingRegistry &registry, NativeTerrainShapingRegistryBatch batch) {
    try { (void)registry.apply(batch); VWB_EXPECT(false); }
    catch (const NativeTerrainShapingRegistryRejected &error) { return error.reason(); }
    return NativeTerrainShapingRegistryRejectReason::invalid_resolution;
}

NativeTerrainShapingRegistryRejectReason retire_rejection(
    NativeTerrainShapingRegistry &registry, NativeTerrainShapingRegistryRetirement retirement) {
    try { (void)registry.retire(retirement); VWB_EXPECT(false); }
    catch (const NativeTerrainShapingRegistryRejected &error) { return error.reason(); }
    return NativeTerrainShapingRegistryRejectReason::invalid_resolution;
}

NativeTerrainShapingRegistryRejectReason constructor_rejection(
    WorldSourceDefinition definition, NativeSiteSourcePolicy policy,
    const NativeTerrainShapingRegistryLimits limits = {}) {
    try { const NativeTerrainShapingRegistry registry(std::move(definition), std::move(policy), limits); (void)registry; VWB_EXPECT(false); }
    catch (const NativeTerrainShapingRegistryRejected &error) { return error.reason(); }
    return NativeTerrainShapingRegistryRejectReason::invalid_resolution;
}

std::vector<NativeSiteSourceRegionKey> present_regions(
    const WorldSourceDefinition &definition, const std::size_t count) {
    std::vector<NativeSiteSourceRegionKey> result;
    for (std::int32_t z = -20; z <= 20 && result.size() < count; ++z)
        for (std::int32_t x = -20; x <= 20 && result.size() < count; ++x)
            if (native_site_source_candidate_for_region(definition, {x, z})) result.push_back({x, z});
    return result;
}

std::int32_t floor_page(const std::int32_t cell) {
    std::int32_t result = cell / NativeTerrainShapingSnapshot::PAGE_CELLS;
    if (cell < 0 && cell % NativeTerrainShapingSnapshot::PAGE_CELLS != 0) --result;
    return result;
}

} // namespace

VWB_TEST(borrowed_site_candidate_cursor_matches_synchronous_presence_and_scalar_channels) {
    for (const std::string seed : {std::string("atlas-1492"), std::string("\xf0\x9f\x8c\xb2 seed")}) {
        const WorldSourceDefinition definition = definition_for(seed);
        for (const NativeSiteSourceRegionKey region : {
                NativeSiteSourceRegionKey{0, 0}, NativeSiteSourceRegionKey{1, -1},
                NativeSiteSourceRegionKey{-19, 7}, NativeSiteSourceRegionKey{101, 101}}) {
            const auto expected = native_site_source_candidate_for_region(definition, region);
            BorrowedSiteCandidateCursor cursor;
            const auto insufficient = cursor.begin(definition, region, 0U);
            VWB_EXPECT_EQ(0U, insufficient.consumed_ops);
            VWB_EXPECT_EQ(BorrowedSiteCandidateCursor::Status::idle, cursor.status());
            const auto begun = cursor.begin(definition, region, 1U);
            VWB_EXPECT_EQ(1U, begun.consumed_ops);
            const std::uint32_t quotas[] = {0U, 1U, 2U, 3U, 7U, 63U, 64U};
            for (std::size_t call = 0U;
                 call < 100000U && cursor.status() == BorrowedSiteCandidateCursor::Status::pending;
                 ++call) {
                const std::uint32_t offered = quotas[call % 7U];
                const auto step = cursor.advance(definition, offered);
                VWB_EXPECT(step.consumed_ops <= offered);
                VWB_EXPECT(step.consumed_ops <= 64U);
            }
            VWB_EXPECT(cursor.status() != BorrowedSiteCandidateCursor::Status::pending);
            if (!expected) {
                VWB_EXPECT_EQ(BorrowedSiteCandidateCursor::Status::absent, cursor.status());
                continue;
            }
            VWB_EXPECT_EQ(BorrowedSiteCandidateCursor::Status::ready, cursor.status());
            VWB_EXPECT_EQ(expected->center_x, cursor.center_x());
            VWB_EXPECT_EQ(expected->center_z, cursor.center_z());
            VWB_EXPECT_EQ(expected->recipe_seed, cursor.recipe_seed());
            VWB_EXPECT_EQ(expected->declared_influence_cells, cursor.declared_influence_cells());
        }
    }
}

VWB_TEST(borrowed_shaping_page_cursor_matches_public_registry_readiness) {
    NativeTerrainShapingRegistry registry(definition_for(), policy_for());
    const NativeSiteSourceRegionKey region{0, 0};
    const auto candidate = native_site_source_candidate_for_region(registry.definition(), region);
    VWB_EXPECT(candidate.has_value());
    const NativeTerrainPageKey affected{floor_page(candidate->center_x), floor_page(candidate->center_z)};
    const auto compare = [&](const NativeTerrainPageKey page) {
        BorrowedShapingPageCursor cursor;
        VWB_EXPECT_EQ(0U, cursor.begin(page, 0U).consumed_ops);
        VWB_EXPECT_EQ(1U, cursor.begin(page, 1U).consumed_ops);
        const std::uint32_t quotas[] = {0U, 1U, 3U, 23U, 24U, 63U, 64U};
        for (std::size_t call = 0U;
             call < 100000U && cursor.status() == BorrowedShapingPageCursor::Status::pending;
             ++call) {
            const std::uint32_t offered = quotas[call % 7U];
            const auto step = registry.advance_borrowed_page(cursor, offered);
            VWB_EXPECT(step.consumed_ops <= offered);
            VWB_EXPECT(step.consumed_ops <= 64U);
        }
        const auto pin = registry.pin_page(page);
        switch (pin.readiness()) {
        case NativeTerrainShapingPageReadiness::ready:
            VWB_EXPECT_EQ(BorrowedShapingPageCursor::Status::ready, cursor.status());
            VWB_EXPECT_EQ(pin.snapshot()->site_fragments().size(), cursor.profile_count());
            break;
        case NativeTerrainShapingPageReadiness::unresolved:
            VWB_EXPECT_EQ(BorrowedShapingPageCursor::Status::unresolved, cursor.status()); break;
        case NativeTerrainShapingPageReadiness::failed:
            VWB_EXPECT_EQ(BorrowedShapingPageCursor::Status::failed, cursor.status()); break;
        }
    };
    compare(affected);
    compare({0, 0});
    registry.apply({registry.revision(), {absent_resolution(registry, region)}});
    compare(affected);
    NativeTerrainShapingRegistry prepared(definition_for(), policy_for());
    const auto admitted = admit_native_site_terrain_profile(prepared.definition(), profile_for(*candidate));
    prepared.apply({prepared.revision(), {prepared_resolution(prepared, region, admitted)}});
    BorrowedShapingPageCursor prepared_cursor;
    VWB_EXPECT_EQ(1U, prepared_cursor.begin(affected, 1U).consumed_ops);
    for (std::size_t call = 0U;
         call < 100000U && prepared_cursor.status() == BorrowedShapingPageCursor::Status::pending;
         ++call) (void)prepared.advance_borrowed_page(prepared_cursor, 64U);
    VWB_EXPECT_EQ(BorrowedShapingPageCursor::Status::ready, prepared_cursor.status());
    VWB_EXPECT_EQ(1U, prepared_cursor.profile_count());
    NativeTerrainShapingRegistry failed(definition_for(), policy_for());
    failed.apply({failed.revision(), {failed_resolution(failed, region)}});
    BorrowedShapingPageCursor failed_cursor;
    VWB_EXPECT_EQ(1U, failed_cursor.begin(affected, 1U).consumed_ops);
    for (std::size_t call = 0U;
         call < 100000U && failed_cursor.status() == BorrowedShapingPageCursor::Status::pending;
         ++call) {
        const auto step = failed.advance_borrowed_page(failed_cursor, 64U);
        VWB_EXPECT(step.consumed_ops <= 64U);
    }
    VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::failed, failed.pin_page(affected).readiness());
    VWB_EXPECT_EQ(BorrowedShapingPageCursor::Status::failed, failed_cursor.status());
}

VWB_TEST(borrowed_shaping_vwsh_digest_matches_synchronous_empty_and_prepared_pages) {
    NativeTerrainShapingRegistry registry(definition_for(), policy_for());
    const NativeSiteSourceRegionKey region{0, 0};
    const auto candidate = native_site_source_candidate_for_region(registry.definition(), region);
    VWB_EXPECT(candidate.has_value());
    const NativeTerrainPageKey page{floor_page(candidate->center_x), floor_page(candidate->center_z)};
    const auto compare = [&](const std::array<NativeTownRegionOverride, 9> &towns,
        const std::size_t town_count) {
        BorrowedShapingPageCursor readiness;
        VWB_EXPECT_EQ(1U, readiness.begin(page, 1U).consumed_ops);
        for (std::size_t call = 0U;
             call < 100000U && readiness.status() == BorrowedShapingPageCursor::Status::pending;
             ++call) (void)registry.advance_borrowed_page(readiness, 64U);
        VWB_EXPECT_EQ(BorrowedShapingPageCursor::Status::ready, readiness.status());
        BorrowedShapingIdentityCursor identity;
        const std::uint32_t quotas[] = {0U, 1U, 7U, 8U, 23U, 24U, 63U, 64U};
        for (std::size_t call = 0U;
             call < 100000U && identity.status() != BorrowedShapingIdentityCursor::Status::ready;
             ++call) {
            const std::uint32_t offered = quotas[call % 8U];
            const auto step = registry.advance_borrowed_page_identity(
                readiness, identity, towns, town_count, offered);
            VWB_EXPECT(step.consumed_ops <= offered);
            VWB_EXPECT(step.consumed_ops <= 64U);
            VWB_EXPECT(step.status != BorrowedShapingIdentityCursor::Status::failed);
        }
        VWB_EXPECT_EQ(BorrowedShapingIdentityCursor::Status::ready, identity.status());
        std::vector<NativeTownRegionOverride> town_list;
        for (std::size_t index = 0U; index < town_count; ++index) town_list.push_back(towns[index]);
        const auto pin = registry.pin_page(page, std::move(town_list));
        VWB_EXPECT_EQ(pin.snapshot()->physical_content_identity().digest, identity.digest());
    };
    registry.apply({registry.revision(), {absent_resolution(registry, region)}});
    std::array<NativeTownRegionOverride, 9> towns{};
    compare(towns, 0U);
    towns[0].region_x = page.x; towns[0].region_z = page.z;
    towns[0].has_town = false;
    compare(towns, 1U);
    VWB_EXPECT(!(registry.pin_page(page).snapshot()->physical_content_identity()
        == registry.pin_page(page, {towns[0]}).snapshot()->physical_content_identity()));
    NativeTerrainShapingRegistry prepared(definition_for(), policy_for());
    const auto admitted = admit_native_site_terrain_profile(prepared.definition(), profile_for(*candidate));
    prepared.apply({prepared.revision(), {prepared_resolution(prepared, region, admitted)}});
    BorrowedShapingPageCursor readiness;
    VWB_EXPECT_EQ(1U, readiness.begin(page, 1U).consumed_ops);
    for (std::size_t call = 0U;
         call < 100000U && readiness.status() == BorrowedShapingPageCursor::Status::pending;
         ++call) (void)prepared.advance_borrowed_page(readiness, 64U);
    VWB_EXPECT_EQ(BorrowedShapingPageCursor::Status::ready, readiness.status());
    BorrowedShapingIdentityCursor identity;
    for (std::size_t call = 0U;
         call < 100000U && identity.status() != BorrowedShapingIdentityCursor::Status::ready;
         ++call) {
        const auto step = prepared.advance_borrowed_page_identity(readiness, identity, towns, 1U, 64U);
        VWB_EXPECT(step.consumed_ops <= 64U);
        VWB_EXPECT(step.status != BorrowedShapingIdentityCursor::Status::failed);
    }
    VWB_EXPECT_EQ(BorrowedShapingIdentityCursor::Status::ready, identity.status());
    VWB_EXPECT_EQ(prepared.pin_page(page, {towns[0]}).snapshot()->physical_content_identity().digest,
        identity.digest());
}

VWB_TEST(native_site_source_field_matches_godot_sha_unicode_negative_and_extreme_goldens) {
    VWB_EXPECT((NativeSiteSourceRegionKey{1, 2} == NativeSiteSourceRegionKey{1, 2}));
    VWB_EXPECT(!(NativeSiteSourceRegionKey{1, 2} == NativeSiteSourceRegionKey{2, 2}));
    VWB_EXPECT(!(NativeSiteSourceRegionKey{1, 2} == NativeSiteSourceRegionKey{1, 3}));
    const auto atlas = definition_for();
    auto candidate = native_site_source_candidate_for_region(atlas, {0, 0});
    VWB_EXPECT(candidate.has_value()); VWB_EXPECT_EQ(std::string("citadel-site-v1:10:atlas-1492:0,0"), candidate->site_id);
    VWB_EXPECT_EQ(830, candidate->center_x); VWB_EXPECT_EQ(1214, candidate->center_z);
    VWB_EXPECT_EQ(921256297U, candidate->recipe_seed);
    VWB_EXPECT_EQ((NativeHorizontalRect{446, 830, 769, 769}), candidate->declared_influence_cells);
    candidate = native_site_source_candidate_for_region(atlas, {-1, -3});
    VWB_EXPECT(candidate.has_value()); VWB_EXPECT_EQ(-705, candidate->center_x); VWB_EXPECT_EQ(-5321, candidate->center_z);
    VWB_EXPECT_EQ(512763292U, candidate->recipe_seed);
    candidate = native_site_source_candidate_for_region(atlas, {1, -3});
    VWB_EXPECT(candidate.has_value()); VWB_EXPECT_EQ(3236, candidate->center_x); VWB_EXPECT_EQ(-5431, candidate->center_z);
    VWB_EXPECT_EQ(1298433643U, candidate->recipe_seed);
    VWB_EXPECT_EQ((NativeHorizontalRect{2852, -5815, 769, 769}), candidate->declared_influence_cells);
    VWB_EXPECT(!native_site_source_candidate_for_region(atlas, {-2, -2}).has_value());

    const std::string unicode = u8"雪🏰é";
    candidate = native_site_source_candidate_for_region(definition_for(unicode), {-17, -20});
    VWB_EXPECT(candidate.has_value()); VWB_EXPECT_EQ(std::string(u8"citadel-site-v1:4:雪🏰é:-17,-20"), candidate->site_id);
    VWB_EXPECT_EQ(-33908, candidate->center_x); VWB_EXPECT_EQ(-40178, candidate->center_z);
    VWB_EXPECT_EQ(895195507U, candidate->recipe_seed);
    VWB_EXPECT(!native_site_source_candidate_for_region(definition_for(u8"é🌲"), {-1, -1}).has_value());
    candidate = native_site_source_candidate_for_region(definition_for(u8"é🌲"), {-1, -1});
    VWB_EXPECT(candidate.has_value()); VWB_EXPECT_EQ(std::string(u8"citadel-site-v1:3:é🌲:-1,-1"), candidate->site_id);
    VWB_EXPECT_EQ(-747, candidate->center_x); VWB_EXPECT_EQ(-1252, candidate->center_z);
    VWB_EXPECT_EQ(680838731U, candidate->recipe_seed);
    VWB_EXPECT(native_site_source_candidate_for_region(definition_for("presence-boundary"), {74, -96}).has_value());
    VWB_EXPECT(!native_site_source_candidate_for_region(definition_for("presence-boundary"), {-41, -98}).has_value());
    candidate = native_site_source_candidate_for_region(definition_for(" atlas "), {2, -5});
    VWB_EXPECT(candidate.has_value()); VWB_EXPECT_EQ(std::string("citadel-site-v1:7: atlas :2,-5"), candidate->site_id);
    VWB_EXPECT_EQ(4808, candidate->center_x); VWB_EXPECT_EQ(-9147, candidate->center_z);

    candidate = native_site_source_candidate_for_region(atlas, {-1048576, -16});
    VWB_EXPECT(candidate.has_value()); VWB_EXPECT_EQ(std::numeric_limits<std::int32_t>::min() + 1097, candidate->center_x);
    VWB_EXPECT_EQ(-32033, candidate->center_z); VWB_EXPECT_EQ(1730451979U, candidate->recipe_seed);
    candidate = native_site_source_candidate_for_region(atlas, {1048575, -11});
    VWB_EXPECT(candidate.has_value()); VWB_EXPECT_EQ(2147482976, candidate->center_x);
    VWB_EXPECT_EQ(-21712, candidate->center_z); VWB_EXPECT_EQ(1427995055U, candidate->recipe_seed);
    VWB_EXPECT(!native_site_source_candidate_for_region(atlas, {-1048577, 0}).has_value());
    VWB_EXPECT(!native_site_source_candidate_for_region(atlas, {1048576, 0}).has_value());
    VWB_EXPECT(!native_site_source_candidate_for_region(atlas, {0, -1048577}).has_value());
    VWB_EXPECT(!native_site_source_candidate_for_region(atlas, {0, 1048576}).has_value());
    VWB_EXPECT(!native_site_source_candidate_for_region(definition_for(""), {0, 0}).has_value());
}

VWB_TEST(native_site_source_field_and_profile_admission_cover_full_valid_astral_seed_domain) {
    const std::string tree = u8"🌲";
    std::string seed512; for (int index = 0; index < 512; ++index) seed512 += tree;
    std::string seed1024 = seed512 + seed512;
    const auto definition = definition_for(seed1024);
    const auto regions = present_regions(definition, 1); VWB_EXPECT_EQ(1U, static_cast<unsigned>(regions.size()));
    const auto candidate = native_site_source_candidate_for_region(definition, regions[0]); VWB_EXPECT(candidate.has_value());
    VWB_EXPECT(candidate->site_id.size() > 4096); VWB_EXPECT(candidate->site_id.size() <= NativeTerrainShapingSnapshot::MAX_SITE_ID_BYTES);
    const auto profile = admit_native_site_terrain_profile(definition, profile_for(*candidate, seed1024));
    VWB_EXPECT_EQ(candidate->site_id, profile->site_id());
    NativeTerrainShapingRegistry registry(definition, policy_for()); VWB_EXPECT_EQ(1U, static_cast<unsigned>(registry.revision()));

    std::string seed1025 = seed1024 + tree;
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy,
        constructor_rejection(definition_for(seed1025), policy_for()));
}

VWB_TEST(native_shaping_registry_canonicalizes_and_binds_typed_source_policy) {
    NativeSiteSourcePolicy policy = policy_for();
    policy.town_overrides = {{2, -1, true, 560, -280, 30, 14.0}, {-3, 4, false, 0, 0, 0, 0.0},
        {2, -2, true, 560, -560, 22, 13.0}};
    NativeTerrainShapingRegistry first(definition_for(), policy);
    std::reverse(policy.town_overrides.begin(), policy.town_overrides.end());
    NativeTerrainShapingRegistry reordered(definition_for(), policy);
    VWB_EXPECT_EQ(first.policy_content_identity(), reordered.policy_content_identity());
    VWB_EXPECT_EQ(first.content_identity(), reordered.content_identity());
    VWB_EXPECT_EQ(-3, first.policy().town_overrides.front().region_x);
    VWB_EXPECT_EQ(first.source_request_identity({0, 0}), reordered.source_request_identity({0, 0}));
    VWB_EXPECT(!(first.source_request_identity({0, 0}) == first.source_request_identity({1, 0})));
    auto changed = policy; changed.engine_version_utf8 += ".changed";
    NativeTerrainShapingRegistry engine_changed(definition_for(), changed);
    VWB_EXPECT(!(first.policy_content_identity() == engine_changed.policy_content_identity()));
    VWB_EXPECT(!(first.content_identity() == engine_changed.content_identity()));
    changed = policy; changed.town_overrides.pop_back();
    NativeTerrainShapingRegistry town_changed(definition_for(), changed);
    VWB_EXPECT(!(first.policy_content_identity() == town_changed.policy_content_identity()));
    changed = policy; changed.ordinary_spawn_chance = 0.09;
    NativeTerrainShapingRegistry ordinary_changed(definition_for(), changed);
    VWB_EXPECT(!(first.policy_content_identity() == ordinary_changed.policy_content_identity()));
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_region,
        [&]() { try { (void)first.source_request_identity({1048576, 0}); } catch (const NativeTerrainShapingRegistryRejected &e) { return e.reason(); } return NativeTerrainShapingRegistryRejectReason::invalid_resolution; }());
}

VWB_TEST(native_shaping_registry_rejects_invalid_policy_and_limits_without_publishing_state) {
    auto reject_policy = [](NativeSiteSourcePolicy policy) {
        return constructor_rejection(definition_for(), std::move(policy));
    };
    auto value = policy_for(); value.source_policy_revision = 2; VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.survey_generation_policy_revision = 2; VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.engine_version_utf8.clear(); VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.engine_version_utf8.assign(1025, 'x'); VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.engine_version_utf8 = std::string("\xc0\x80", 2); VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.town_overrides.resize(4097); VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.ordinary_region_cells = 33; VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.ordinary_spawn_chance = std::numeric_limits<double>::quiet_NaN(); VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.ordinary_spawn_chance = -0.01; VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.ordinary_spawn_chance = 1.01; VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.town_overrides = {{0, 0, false}, {0, 0, false}}; VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.town_overrides = {{1, 0, true, 279, 0, 30, 1.0}}; VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.town_overrides = {{0, 1, true, 0, 279, 30, 1.0}}; VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.town_overrides = {{0, 0, true, 0, 0, 0, 1.0}}; VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.town_overrides = {{0, 0, true, 0, 0, 153, 1.0}}; VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));
    value = policy_for(); value.town_overrides = {{0, 0, true, 0, 0, 30, std::numeric_limits<double>::infinity()}}; VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, reject_policy(value));

    NativeTerrainShapingRegistryLimits limits; limits.max_resident_resolutions = 0;
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_limits, constructor_rejection(definition_for(), policy_for(), limits));
    limits = {}; limits.max_batch_resolutions = 0;
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_limits, constructor_rejection(definition_for(), policy_for(), limits));
    limits = {}; limits.max_resident_resolutions = 1; limits.max_batch_resolutions = 2;
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_limits, constructor_rejection(definition_for(), policy_for(), limits));
    limits = {}; limits.max_revision = 0;
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_limits, constructor_rejection(definition_for(), policy_for(), limits));
    limits = {}; limits.max_retired_fingerprints = 0;
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_limits, constructor_rejection(definition_for(), policy_for(), limits));
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_policy, constructor_rejection(definition_for(""), policy_for()));
}

VWB_TEST(native_shaping_registry_page_readiness_is_derived_complete_and_fail_closed) {
    NativeTerrainShapingRegistry registry(definition_for(), policy_for());
    const NativeSiteSourceRegionKey region{0, 0};
    const auto candidate = native_site_source_candidate_for_region(registry.definition(), region); VWB_EXPECT(candidate.has_value());
    const NativeTerrainPageKey page{floor_page(candidate->center_x), floor_page(candidate->center_z)};
    const auto initial_identity = registry.content_identity();
    const auto unresolved = registry.pin_page(page);
    VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::unresolved, unresolved.readiness());
    VWB_EXPECT_EQ(1U, static_cast<unsigned>(unresolved.dependencies().size()));
    VWB_EXPECT_EQ(region, unresolved.unresolved_dependencies().front());
    VWB_EXPECT(unresolved.failed_dependencies().empty()); VWB_EXPECT(!unresolved.snapshot());
    // Same 2048-cell source region, but outside the exact derived influence.
    const auto outside = registry.pin_page({0, 0});
    VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::ready, outside.readiness());
    VWB_EXPECT(outside.dependencies().empty()); VWB_EXPECT(outside.snapshot());

    auto absent = absent_resolution(registry, region);
    const auto receipt = registry.apply({registry.revision(), {absent}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryCommitStatus::committed, receipt.status);
    const auto empty = registry.pin_page(page);
    VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::ready, empty.readiness());
    VWB_EXPECT(empty.snapshot()); VWB_EXPECT(empty.snapshot()->site_fragments().empty());
    VWB_EXPECT_EQ(receipt.revision, empty.registry_revision());
    VWB_EXPECT_EQ(registry.content_identity(), empty.registry_content_identity());
    VWB_EXPECT(!(initial_identity == registry.content_identity()));
    VWB_EXPECT_EQ(page, empty.page_key());
    (void)registry.pin_page({-256, 0}); // exact negative SOURCE_REGION_CELLS division

    NativeTerrainShapingRegistry failed(definition_for(), policy_for());
    failed.apply({failed.revision(), {failed_resolution(failed, region)}});
    const auto failure = failed.pin_page(page);
    VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::failed, failure.readiness());
    VWB_EXPECT_EQ(region, failure.failed_dependencies().front()); VWB_EXPECT(!failure.snapshot());
    VWB_EXPECT_THROW(NativeTerrainShapingAdmissionError, failed.pin_page({8000000, 0}));
}

VWB_TEST(native_shaping_registry_prepared_geometry_is_bound_and_page_local) {
    NativeTerrainShapingRegistry registry(definition_for(), policy_for());
    const NativeSiteSourceRegionKey region{0, 0};
    const auto candidate = native_site_source_candidate_for_region(registry.definition(), region); VWB_EXPECT(candidate.has_value());
    const auto handle = admit_native_site_terrain_profile(registry.definition(), profile_for(*candidate));
    auto prepared = prepared_resolution(registry, region, handle);
    registry.apply({registry.revision(), {prepared}});
    const NativeTerrainPageKey page{floor_page(candidate->center_x), floor_page(candidate->center_z)};
    const auto pin = registry.pin_page(page);
    VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::ready, pin.readiness());
    VWB_EXPECT_EQ(1U, static_cast<unsigned>(pin.snapshot()->site_fragments().size()));
    VWB_EXPECT_EQ(handle->full_profile_digest(), pin.snapshot()->site_fragments().front().full_profile_digest);
    const auto repeat = registry.apply({registry.revision(), {prepared}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryCommitStatus::no_change, repeat.status);
    auto changed_raster_value = profile_for(*candidate); changed_raster_value.distance_cells[0] = 2.0F;
    auto changed_raster = prepared_resolution(registry, region,
        admit_native_site_terrain_profile(registry.definition(), changed_raster_value));
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        apply_rejection(registry, {registry.revision(), {changed_raster}}));
    const auto declared_only = registry.pin_page({1, 3});
    VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::ready, declared_only.readiness());
    VWB_EXPECT_EQ(1U, static_cast<unsigned>(declared_only.dependencies().size()));
    VWB_EXPECT(declared_only.snapshot()->site_fragments().empty());
    const auto physical = pin.snapshot()->physical_content_identity();
    const auto provenance = pin.registry_content_identity();

    NativeTerrainShapingRegistry other(definition_for(), policy_for());
    auto other_prepared = prepared_resolution(other, region, handle, 'd');
    other.apply({other.revision(), {other_prepared}});
    const auto other_pin = other.pin_page(page);
    VWB_EXPECT_EQ(physical, other_pin.snapshot()->physical_content_identity());
    VWB_EXPECT(!(provenance == other_pin.registry_content_identity()));
}

VWB_TEST(native_shaping_registry_candidate_dependency_uses_exact_half_open_page_coverage) {
    NativeTerrainShapingRegistry registry(definition_for(), policy_for());
    for (std::int32_t z = -21; z <= -19; ++z) {
        for (std::int32_t x = 10; x <= 12; ++x) {
            const auto pin = registry.pin_page({x, z});
            VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::unresolved, pin.readiness());
            VWB_EXPECT_EQ(1U, static_cast<unsigned>(pin.dependencies().size()));
            VWB_EXPECT_EQ((NativeSiteSourceRegionKey{1, -3}), pin.dependencies().front());
        }
    }
    for (const NativeTerrainPageKey page : {
        NativeTerrainPageKey{9, -20}, NativeTerrainPageKey{13, -20},
        NativeTerrainPageKey{11, -22}, NativeTerrainPageKey{11, -18}}) {
        const auto pin = registry.pin_page(page);
        VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::ready, pin.readiness());
        VWB_EXPECT(pin.dependencies().empty());
        VWB_EXPECT(pin.snapshot());
    }
}

VWB_TEST(native_shaping_registry_atomic_admission_rejects_stale_cross_policy_and_cross_region_receipts) {
    NativeTerrainShapingRegistry registry(definition_for(), policy_for());
    const auto regions = present_regions(registry.definition(), 3); VWB_EXPECT_EQ(3U, static_cast<unsigned>(regions.size()));
    const std::uint64_t original_revision = registry.revision(); const auto original_identity = registry.content_identity();
    auto valid = absent_resolution(registry, regions[0]);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::revision_conflict,
        apply_rejection(registry, {registry.revision() + 1, {valid}}));
    NativeTerrainShapingRegistryLimits one_limit; one_limit.max_resident_resolutions = 4; one_limit.max_batch_resolutions = 1;
    NativeTerrainShapingRegistry one(definition_for(), policy_for(), one_limit);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::batch_limit,
        apply_rejection(one, {one.revision(), {absent_resolution(one, regions[0]), absent_resolution(one, regions[1])}}));
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::duplicate_region,
        apply_rejection(registry, {registry.revision(), {valid, valid}}));
    auto invalid_region = valid; invalid_region.region = {1048576, 0};
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_region,
        apply_rejection(registry, {registry.revision(), {invalid_region}}));
    auto no_candidate = valid; no_candidate.region = {-2, -2}; no_candidate.request_identity = registry.source_request_identity(no_candidate.region);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::candidate_absent,
        apply_rejection(registry, {registry.revision(), {no_candidate}}));
    auto invalid_kind = valid; invalid_kind.kind = static_cast<NativeSiteSourceResolutionKind>(99);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {invalid_kind}}));
    auto cross_region = valid; cross_region.request_identity = registry.source_request_identity(regions[1]);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {cross_region}}));
    auto bad_key = valid; bad_key.worker_source_key = "short";
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {bad_key}}));
    bad_key = valid; bad_key.worker_source_key.assign(64, 'g');
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {bad_key}}));
    auto bad_reason = valid; bad_reason.reason_code.clear();
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {bad_reason}}));
    bad_reason = valid; bad_reason.reason_code.assign(2049, 'x');
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {bad_reason}}));
    bad_reason = valid; bad_reason.reason_code = std::string("\xc0\x80", 2);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {bad_reason}}));
    auto unexpected_receipt = valid; unexpected_receipt.manifest_source_signature = "unexpected";
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {unexpected_receipt}}));
    unexpected_receipt = valid; unexpected_receipt.source_reservation_cells = {1, 1, 1, 1};
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {unexpected_receipt}}));

    VWB_EXPECT_EQ(original_revision, registry.revision()); VWB_EXPECT_EQ(original_identity, registry.content_identity());
}

VWB_TEST(native_shaping_registry_atomic_admission_rejects_bad_prepared_geometry) {
    NativeTerrainShapingRegistry registry(definition_for(), policy_for());
    const auto regions = present_regions(registry.definition(), 1); VWB_EXPECT_EQ(1U, static_cast<unsigned>(regions.size()));
    const std::uint64_t original_revision = registry.revision(); const auto original_identity = registry.content_identity();
    const auto valid = absent_resolution(registry, regions[0]);

    const auto candidate = native_site_source_candidate_for_region(registry.definition(), regions[0]);
    auto profile = profile_for(*candidate); const auto good_handle = admit_native_site_terrain_profile(registry.definition(), profile);
    auto prepared = prepared_resolution(registry, regions[0], good_handle);
    auto prepared_reason = prepared; prepared_reason.reason_code = "unexpected";
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {prepared_reason}}));
    auto no_profile = prepared; no_profile.profile.reset();
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {no_profile}}));
    auto wrong_manifest = prepared; wrong_manifest.manifest_source_signature = "wrong";
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {wrong_manifest}}));
    auto wrong_reservation = prepared; wrong_reservation.source_reservation_cells.width += 1;
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {wrong_reservation}}));
    auto foreign_profile = profile_for(*candidate, "atlas-1493"); foreign_profile.world_seed_utf8 = "atlas-1493";
    auto foreign_handle = admit_native_site_terrain_profile(definition_for("atlas-1493"), foreign_profile);
    auto foreign = prepared; foreign.profile = foreign_handle;
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {foreign}}));

    VWB_EXPECT_EQ(original_revision, registry.revision()); VWB_EXPECT_EQ(original_identity, registry.content_identity());
}

VWB_TEST(native_shaping_registry_atomic_admission_rejects_candidate_geometry_mistranslations) {
    NativeTerrainShapingRegistry registry(definition_for(), policy_for());
    const NativeSiteSourceRegionKey region{0, 0};
    const auto candidate = native_site_source_candidate_for_region(registry.definition(), region);
    auto profile = profile_for(*candidate);
    const auto prepared = prepared_resolution(registry, region,
        admit_native_site_terrain_profile(registry.definition(), profile));
    const auto valid = absent_resolution(registry, region);
    const std::uint64_t original_revision = registry.revision(); const auto original_identity = registry.content_identity();
    profile = profile_for(*candidate); profile.site_id += "-wrong";
    auto wrong_site = prepared; wrong_site.profile = admit_native_site_terrain_profile(registry.definition(), profile);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {wrong_site}}));
    profile = profile_for(*candidate);
    profile.core_cells = {candidate->center_x - 1, candidate->center_z - 1, 386, 3};
    profile.envelope_cells = {candidate->center_x - 2, candidate->center_z - 2, 388, 5};
    profile.reservation_cells = profile.core_cells;
    profile.support_mask.assign(1940, 0); profile.distance_cells.assign(1940, 1.0F);
    profile.ground_root_points.assign(4, profile.origin);
    auto outside_envelope = prepared;
    outside_envelope.profile = admit_native_site_terrain_profile(registry.definition(), profile);
    outside_envelope.manifest_source_signature = outside_envelope.profile->source_signature();
    outside_envelope.source_reservation_cells = merged_source_reservation_for(profile);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {outside_envelope}}));
    profile = profile_for(*candidate); profile.origin.x += 1.0F;
    auto wrong_origin = prepared; wrong_origin.profile = admit_native_site_terrain_profile(registry.definition(), profile);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {wrong_origin}}));
    profile = profile_for(*candidate); profile.origin.z += 1.0F;
    wrong_origin = prepared; wrong_origin.profile = admit_native_site_terrain_profile(registry.definition(), profile);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {wrong_origin}}));

    VWB_EXPECT_EQ(original_revision, registry.revision()); VWB_EXPECT_EQ(original_identity, registry.content_identity());
}

VWB_TEST(native_shaping_registry_atomic_admission_rejects_source_reservation_mistranslations) {
    NativeTerrainShapingRegistry registry(definition_for(), policy_for());
    const NativeSiteSourceRegionKey region{0, 0};
    const auto candidate = native_site_source_candidate_for_region(registry.definition(), region);
    auto profile = profile_for(*candidate);
    const auto prepared = prepared_resolution(registry, region,
        admit_native_site_terrain_profile(registry.definition(), profile));
    const auto valid = absent_resolution(registry, region);
    const std::uint64_t original_revision = registry.revision(); const auto original_identity = registry.content_identity();
    profile = profile_for(*candidate); profile.reservation_cells = {candidate->center_x + 385, candidate->center_z, 1, 1};
    auto outside_reservation = prepared; outside_reservation.profile = admit_native_site_terrain_profile(registry.definition(), profile);
    outside_reservation.manifest_source_signature = outside_reservation.profile->source_signature();
    outside_reservation.source_reservation_cells = merged_source_reservation_for(profile);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {outside_reservation}}));
    for (const NativeHorizontalRect reservation : {
        NativeHorizontalRect{candidate->center_x - 385, candidate->center_z, 1, 1},
        NativeHorizontalRect{candidate->center_x, candidate->center_z - 385, 1, 1},
        NativeHorizontalRect{candidate->center_x, candidate->center_z + 385, 1, 1}}) {
        profile = profile_for(*candidate); profile.reservation_cells = reservation;
        auto outside = prepared; outside.profile = admit_native_site_terrain_profile(registry.definition(), profile);
        outside.manifest_source_signature = outside.profile->source_signature();
        outside.source_reservation_cells = merged_source_reservation_for(profile);
        VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
            apply_rejection(registry, {registry.revision(), {outside}}));
    }
    auto absent_with_profile = valid; absent_with_profile.profile = prepared.profile;
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
        apply_rejection(registry, {registry.revision(), {absent_with_profile}}));
    for (const NativeHorizontalRect receipt : {NativeHorizontalRect{0, 0, 0, 1}, NativeHorizontalRect{0, 0, 1, 0},
        NativeHorizontalRect{1, 0, 0, 0}, NativeHorizontalRect{0, 1, 0, 0}}) {
        auto unexpected = valid; unexpected.source_reservation_cells = receipt;
        VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_resolution,
            apply_rejection(registry, {registry.revision(), {unexpected}}));
    }
    VWB_EXPECT_EQ(original_revision, registry.revision()); VWB_EXPECT_EQ(original_identity, registry.content_identity());

    NativeTerrainShapingRegistry inclusive_boundary(definition_for(), policy_for());
    profile = profile_for(*candidate);
    profile.reservation_cells = {candidate->center_x + 384, candidate->center_z, 1, 1};
    auto boundary = prepared_resolution(inclusive_boundary, region,
        admit_native_site_terrain_profile(inclusive_boundary.definition(), profile));
    boundary.source_reservation_cells = merged_source_reservation_for(profile);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryCommitStatus::committed,
        inclusive_boundary.apply({inclusive_boundary.revision(), {boundary}}).status);
}

VWB_TEST(native_shaping_registry_sorted_lookup_distinguishes_lower_bound_from_exact_region) {
    const auto definition = definition_for();
    auto regions = present_regions(definition, 20);
    std::sort(regions.begin(), regions.end(), [](const auto left, const auto right) {
        return left.x < right.x || (left.x == right.x && left.z < right.z);
    });
    const auto low = regions.front(); const auto high = regions.back();

    NativeTerrainShapingRegistry active(definition_for(), policy_for());
    active.apply({active.revision(), {absent_resolution(active, high)}});
    active.apply({active.revision(), {absent_resolution(active, low)}});
    VWB_EXPECT_EQ(2U, static_cast<unsigned>(active.resident_resolution_count()));

    NativeTerrainShapingRegistry retired(definition_for(), policy_for());
    retired.apply({retired.revision(), {absent_resolution(retired, high)}});
    retired.retire({retired.revision(), {high}});
    retired.apply({retired.revision(), {absent_resolution(retired, low)}});
    VWB_EXPECT_EQ(1U, static_cast<unsigned>(retired.retired_fingerprint_count()));

    NativeTerrainShapingRegistry missing(definition_for(), policy_for());
    missing.apply({missing.revision(), {absent_resolution(missing, high)}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        retire_rejection(missing, {missing.revision(), {low}}));

    NativeTerrainShapingRegistry unresolved(definition_for(), policy_for());
    unresolved.apply({unresolved.revision(), {absent_resolution(unresolved, high)}});
    const auto low_candidate = native_site_source_candidate_for_region(unresolved.definition(), low);
    const auto low_page = NativeTerrainPageKey{floor_page(low_candidate->center_x), floor_page(low_candidate->center_z)};
    VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::unresolved, unresolved.pin_page(low_page).readiness());

    NativeSiteSourceRegionKey same_x_low{}; NativeSiteSourceRegionKey same_x_high{}; bool found_same_x = false;
    for (std::int32_t x = -20; x <= 20 && !found_same_x; ++x) {
        std::optional<NativeSiteSourceRegionKey> first;
        for (std::int32_t z = -20; z <= 20; ++z) {
            if (!native_site_source_candidate_for_region(definition, {x, z})) continue;
            if (!first) { first = NativeSiteSourceRegionKey{x, z}; continue; }
            same_x_low = *first; same_x_high = {x, z}; found_same_x = true; break;
        }
    }
    VWB_EXPECT(found_same_x);
    NativeTerrainShapingRegistry same_x(definition_for(), policy_for());
    same_x.apply({same_x.revision(), {
        absent_resolution(same_x, same_x_high), absent_resolution(same_x, same_x_low)}});
    VWB_EXPECT_EQ(2U, static_cast<unsigned>(same_x.resident_resolution_count()));
}

VWB_TEST(native_shaping_registry_terminal_idempotency_conflict_capacity_and_revision_limits_are_explicit) {
    const auto definition = definition_for(); const auto regions = present_regions(definition, 3);
    NativeTerrainShapingRegistry registry(definition, policy_for());
    auto absent = absent_resolution(registry, regions[0]);
    auto receipt = registry.apply({registry.revision(), {absent}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryCommitStatus::committed, receipt.status);
    const auto no_change = registry.apply({registry.revision(), {absent}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryCommitStatus::no_change, no_change.status);
    VWB_EXPECT_EQ(receipt.revision, no_change.revision);
    auto conflicting = absent; conflicting.worker_source_key.assign(64, 'f');
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        apply_rejection(registry, {registry.revision(), {conflicting}}));
    conflicting = failed_resolution(registry, regions[0]);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        apply_rejection(registry, {registry.revision(), {conflicting}}));
    conflicting = absent; conflicting.reason_code = "terrain_relief_exceeds_supported_apron";
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        apply_rejection(registry, {registry.revision(), {conflicting}}));
    const auto empty = registry.apply({registry.revision(), {}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryCommitStatus::no_change, empty.status);

    NativeTerrainShapingRegistry digits(definition_for(), policy_for());
    digits.apply({digits.revision(), {absent_resolution(digits, regions[1], '0')}});

    NativeTerrainShapingRegistryLimits capacity_limits; capacity_limits.max_resident_resolutions = 1; capacity_limits.max_batch_resolutions = 1;
    NativeTerrainShapingRegistry capacity(definition_for(), policy_for(), capacity_limits);
    capacity.apply({capacity.revision(), {absent_resolution(capacity, regions[0])}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::capacity_exceeded,
        apply_rejection(capacity, {capacity.revision(), {absent_resolution(capacity, regions[1])}}));
    NativeTerrainShapingRegistryLimits revision_limits; revision_limits.max_resident_resolutions = 2;
    revision_limits.max_batch_resolutions = 2; revision_limits.max_revision = 1;
    NativeTerrainShapingRegistry exhausted(definition_for(), policy_for(), revision_limits);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::revision_exhausted,
        apply_rejection(exhausted, {exhausted.revision(), {absent_resolution(exhausted, regions[0])}}));
}

VWB_TEST(native_shaping_registry_retirement_is_atomic_reconstructible_and_preserves_old_page_pins) {
    NativeTerrainShapingRegistry registry(definition_for(), policy_for());
    const NativeSiteSourceRegionKey region{0, 0};
    const auto candidate = native_site_source_candidate_for_region(registry.definition(), region);
    const NativeTerrainPageKey page{floor_page(candidate->center_x), floor_page(candidate->center_z)};
    const auto profile = admit_native_site_terrain_profile(registry.definition(), profile_for(*candidate));
    const auto prepared = prepared_resolution(registry, region, profile);
    registry.apply({registry.revision(), {prepared}});
    const auto old_pin = registry.pin_page(page); const auto old_identity = old_pin.snapshot()->physical_content_identity();
    const auto empty_retirement = registry.retire({registry.revision(), {}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryCommitStatus::no_change, empty_retirement.status);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::revision_conflict,
        retire_rejection(registry, {registry.revision() + 1, {region}}));
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::duplicate_region,
        retire_rejection(registry, {registry.revision(), {region, region}}));
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::invalid_region,
        retire_rejection(registry, {registry.revision(), {{1048576, 0}}}));
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        retire_rejection(registry, {registry.revision(), {{1, 1}}}));
    const auto retired = registry.retire({registry.revision(), {region}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryCommitStatus::committed, retired.status);
    VWB_EXPECT_EQ(0U, static_cast<unsigned>(registry.resident_resolution_count()));
    VWB_EXPECT_EQ(1U, static_cast<unsigned>(registry.retired_fingerprint_count()));
    VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::unresolved, registry.pin_page(page).readiness());
    VWB_EXPECT_EQ(old_identity, old_pin.snapshot()->physical_content_identity());
    VWB_EXPECT_EQ(1U, static_cast<unsigned>(old_pin.snapshot()->site_fragments().size()));
    auto changed_profile_value = profile_for(*candidate); changed_profile_value.distance_cells[0] = 2.0F;
    const auto changed_profile = admit_native_site_terrain_profile(registry.definition(), changed_profile_value);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        apply_rejection(registry, {registry.revision(), {prepared_resolution(registry, region, changed_profile)}}));
    auto changed_signature_value = profile_for(*candidate); changed_signature_value.source_signature = "changed-signature";
    const auto changed_signature = admit_native_site_terrain_profile(registry.definition(), changed_signature_value);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        apply_rejection(registry, {registry.revision(), {prepared_resolution(registry, region, changed_signature)}}));
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        apply_rejection(registry, {registry.revision(), {absent_resolution(registry, region)}}));
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        apply_rejection(registry, {registry.revision(), {failed_resolution(registry, region)}}));
    auto changed_key = prepared_resolution(registry, region, profile); changed_key.worker_source_key.assign(64, 'f');
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        apply_rejection(registry, {registry.revision(), {changed_key}}));
    registry.apply({registry.revision(), {prepared_resolution(registry, region, profile)}});
    VWB_EXPECT_EQ(old_identity, registry.pin_page(page).snapshot()->physical_content_identity());
    VWB_EXPECT_EQ(0U, static_cast<unsigned>(registry.retired_fingerprint_count()));
}

VWB_TEST(native_shaping_registry_retirement_rejects_sticky_failures_and_reconstructs_absence) {
    const NativeSiteSourceRegionKey region{0, 0};
    NativeTerrainShapingRegistry failed(definition_for(), policy_for());
    failed.apply({failed.revision(), {failed_resolution(failed, region)}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        retire_rejection(failed, {failed.revision(), {region}}));
    NativeTerrainShapingRegistry absent_compact(definition_for(), policy_for());
    const auto compact_regions = present_regions(absent_compact.definition(), 2);
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        retire_rejection(absent_compact, {absent_compact.revision(), {{-20, -20}}}));
}

VWB_TEST(native_shaping_registry_retirement_reconstructs_exact_absence) {
    NativeTerrainShapingRegistry absent_compact(definition_for(), policy_for());
    const auto compact_regions = present_regions(absent_compact.definition(), 2);
    auto compact_absent = absent_resolution(absent_compact, compact_regions[0]);
    absent_compact.apply({absent_compact.revision(), {compact_absent}});
    absent_compact.retire({absent_compact.revision(), {compact_regions[0]}});
    VWB_EXPECT_EQ(1U, static_cast<unsigned>(absent_compact.retired_fingerprint_count()));
    auto changed_reason = compact_absent; changed_reason.reason_code = "terrain_relief_exceeds_supported_apron";
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::terminal_conflict,
        apply_rejection(absent_compact, {absent_compact.revision(), {changed_reason}}));
    absent_compact.apply({absent_compact.revision(), {compact_absent}});
    VWB_EXPECT_EQ(0U, static_cast<unsigned>(absent_compact.retired_fingerprint_count()));
}

VWB_TEST(native_shaping_registry_retirement_enforces_atomic_limits) {
    const NativeSiteSourceRegionKey region{0, 0};
    NativeTerrainShapingRegistryLimits one; one.max_resident_resolutions = 4; one.max_batch_resolutions = 1;
    NativeTerrainShapingRegistry bounded(definition_for(), policy_for(), one);
    bounded.apply({bounded.revision(), {absent_resolution(bounded, region)}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::batch_limit,
        retire_rejection(bounded, {bounded.revision(), {region, {1, 1}}}));
    NativeTerrainShapingRegistryLimits revision_limit; revision_limit.max_resident_resolutions = 2;
    revision_limit.max_batch_resolutions = 2; revision_limit.max_revision = 2;
    NativeTerrainShapingRegistry exhausted(definition_for(), policy_for(), revision_limit);
    exhausted.apply({exhausted.revision(), {absent_resolution(exhausted, region)}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::revision_exhausted,
        retire_rejection(exhausted, {exhausted.revision(), {region}}));

    const auto two_regions = present_regions(definition_for(), 2);
    NativeTerrainShapingRegistryLimits compact_limit; compact_limit.max_resident_resolutions = 2;
    compact_limit.max_batch_resolutions = 2; compact_limit.max_retired_fingerprints = 1;
    NativeTerrainShapingRegistry compact(definition_for(), policy_for(), compact_limit);
    compact.apply({compact.revision(), {absent_resolution(compact, two_regions[0]), absent_resolution(compact, two_regions[1])}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::capacity_exceeded,
        retire_rejection(compact, {compact.revision(), {two_regions[0], two_regions[1]}}));
    compact.retire({compact.revision(), {two_regions[0]}});
    VWB_EXPECT_EQ(NativeTerrainShapingRegistryRejectReason::capacity_exceeded,
        retire_rejection(compact, {compact.revision(), {two_regions[1]}}));
}
