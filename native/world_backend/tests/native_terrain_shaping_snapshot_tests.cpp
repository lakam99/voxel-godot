#include "test_harness.hpp"

#include "../core/native_terrain_shaping_snapshot.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

WorldSourceDefinition shaping_definition(const std::string &seed = "atlas-1492") {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
    descriptor.revisions.terrain_generator_revision = 8;
    descriptor.revisions.lattice_query_revision = 6;
    descriptor.revisions.cell_center_query_revision = 7;
    descriptor.revisions.surface_column_query_revision = 8;
    return WorldSourceDefinition(std::move(descriptor));
}

NativeTerrainShapingRequest request_for(const NativeTerrainPageKey page = {0, 0}, const std::uint64_t revision = 1) {
    NativeTerrainShapingRequest request; request.generation_revision = revision; request.page_key = page; return request;
}

NativeTownRegionOverride town_override(
    const std::int32_t region_x, const std::int32_t region_z, const std::int32_t radius, const double level) {
    NativeTownRegionOverride value;
    value.region_x = region_x; value.region_z = region_z; value.has_town = true;
    value.town = {region_x, region_z,
        static_cast<std::int32_t>(static_cast<std::int64_t>(region_x) * NativeTerrainShapingSnapshot::PAGE_CELLS),
        static_cast<std::int32_t>(static_cast<std::int64_t>(region_z) * NativeTerrainShapingSnapshot::PAGE_CELLS), radius, level};
    return value;
}

NativeTownRegionOverride empty_town_override(const std::int32_t region_x, const std::int32_t region_z) {
    NativeTownRegionOverride value; value.region_x = region_x; value.region_z = region_z; return value;
}

void suppress_all_towns(NativeTerrainShapingRequest &request) {
    for (std::int32_t z = request.page_key.z - 1; z <= request.page_key.z + 1; ++z)
        for (std::int32_t x = request.page_key.x - 1; x <= request.page_key.x + 1; ++x)
            request.town_overrides.push_back(empty_town_override(x, z));
}

NativeSiteTerrainProfile small_site(
    const std::string &id, const std::int32_t x, const std::int32_t z, const double level = 5.0) {
    NativeSiteTerrainProfile site;
    site.world_seed_utf8 = "atlas-1492"; site.site_id = id; site.source_signature = "source:" + id;
    site.core_cells = {x + 1, z + 1, 3, 3}; site.envelope_cells = {x, z, 5, 5};
    site.reservation_cells = site.core_cells;
    site.level_meters = level; site.apron_cells = 1;
    site.origin = {static_cast<float>((site.core_cells.x + 1) * site.cell_size_meters), static_cast<float>(level),
        static_cast<float>((site.core_cells.z + 1) * site.cell_size_meters)};
    site.support_mask.assign(25, 0); site.support_mask[6] = 1;
    site.distance_cells.assign(25, 1.0F); site.distance_cells[6] = 0.0F;
    site.ground_root_points.assign(4, site.origin);
    return site;
}

NativeAdmittedSiteTerrainProfileHandle admit_site(
    NativeSiteTerrainProfile site, const std::string &seed = "atlas-1492") {
    return admit_native_site_terrain_profile(shaping_definition(seed), std::move(site));
}

NativeTerrainShapingSnapshot snapshot_for(NativeTerrainShapingRequest request, const std::string &seed = "atlas-1492") {
    return NativeTerrainShapingSnapshot(shaping_definition(seed), std::move(request));
}

NativeTerrainShapingAdmissionFailure rejected_failure(NativeTerrainShapingRequest request) {
    try { const auto unused = snapshot_for(std::move(request)); (void)unused; VWB_EXPECT(false); }
    catch (const NativeTerrainShapingAdmissionError &error) { return error.failure(); }
    return NativeTerrainShapingAdmissionFailure::invalid_site;
}

bool near(const double left, const double right, const double tolerance = 1.0e-9) {
    return std::abs(left - right) <= tolerance;
}

} // namespace

VWB_TEST(borrowed_shaping_vwsh_stream_preserves_site_and_crop_order_and_rejects_overlap) {
    const WorldSourceDefinition definition = shaping_definition();
    const NativeTerrainPageKey page{0, 0};
    const auto bounds = native_terrain_page_bounds(page);
    VWB_EXPECT(bounds.has_value());
    const auto a = admit_site(small_site("a", 12, 0));
    const auto b = admit_site(small_site("b", 0, 0));
    const auto prefixed = admit_site(small_site("ab", 25, 0));
    std::array<const NativeAdmittedSiteTerrainProfile *, 4> profiles{b.get(), prefixed.get(), a.get()};
    std::array<NativeTownRegionOverride, 9> towns{};
    towns[0] = empty_town_override(0, 0);
    towns[1] = town_override(-1, 0, 30, 12.0);
    const auto drain = [&](BorrowedShapingIdentityCursor &cursor,
        const std::array<const NativeAdmittedSiteTerrainProfile *, 4> &input) {
        const std::uint32_t quotas[] = {0U, 1U, 2U, 3U, 63U, 64U};
        for (std::size_t call = 0U;
             call < 100000U && cursor.status() == BorrowedShapingIdentityCursor::Status::pending;
             ++call) {
            const std::uint32_t offered = quotas[call % 6U];
            const auto step = cursor.advance(definition, input, offered);
            VWB_EXPECT(step.consumed_ops <= offered);
            VWB_EXPECT(step.consumed_ops <= 64U);
        }
    };
    BorrowedShapingIdentityCursor cursor;
    VWB_EXPECT_EQ(0U, cursor.begin(page, *bounds, towns, 2U, 3U, 15U).consumed_ops);
    VWB_EXPECT_EQ(16U, cursor.begin(page, *bounds, towns, 2U, 3U, 16U).consumed_ops);
    VWB_EXPECT_EQ(0U, cursor.begin(page, *bounds, towns, 2U, 3U, 64U).consumed_ops);
    VWB_EXPECT_EQ(0U, cursor.advance(definition, profiles, 0U).consumed_ops);
    (void)cursor.advance(definition, profiles, 64U);
    cursor.reset();
    VWB_EXPECT_EQ(16U, cursor.begin(page, *bounds, towns, 2U, 3U, 16U).consumed_ops);
    drain(cursor, profiles);
    VWB_EXPECT_EQ(BorrowedShapingIdentityCursor::Status::ready, cursor.status());
    VWB_EXPECT_EQ(0U, cursor.advance(definition, profiles, 64U).consumed_ops);
    NativeTerrainShapingRequest request = request_for(page);
    request.town_overrides = {towns[0], towns[1]};
    request.site_profiles = {b, prefixed, a};
    const auto sync = snapshot_for(std::move(request));
    VWB_EXPECT_EQ(sync.physical_content_identity().digest, cursor.digest());

    const auto duplicate = admit_site(small_site("a", 25, 0));
    profiles = {a.get(), duplicate.get(), nullptr, nullptr};
    cursor.reset();
    VWB_EXPECT_EQ(16U, cursor.begin(page, *bounds, towns, 0U, 2U, 16U).consumed_ops);
    drain(cursor, profiles);
    VWB_EXPECT_EQ(BorrowedShapingIdentityCursor::Status::failed, cursor.status());

    const auto overlap = admit_site(small_site("c", 13, 0));
    profiles = {a.get(), overlap.get(), nullptr, nullptr};
    cursor.reset();
    VWB_EXPECT_EQ(16U, cursor.begin(page, *bounds, towns, 0U, 2U, 16U).consumed_ops);
    drain(cursor, profiles);
    VWB_EXPECT_EQ(BorrowedShapingIdentityCursor::Status::failed, cursor.status());

    cursor.reset();
    towns[0] = town_override(0, 0, 0, 12.0);
    VWB_EXPECT_EQ(16U, cursor.begin(page, *bounds, towns, 1U, 0U, 16U).consumed_ops);
    drain(cursor, {});
    VWB_EXPECT_EQ(BorrowedShapingIdentityCursor::Status::failed, cursor.status());
}

VWB_TEST(native_shaping_page_admission_requires_revision_valid_page_and_scoped_unique_town_dependencies) {
    VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::missing_generation_revision, rejected_failure({}));
    for (const NativeTerrainPageKey page : {
        NativeTerrainPageKey{std::numeric_limits<std::int32_t>::min(), 0},
        NativeTerrainPageKey{std::numeric_limits<std::int32_t>::max(), 0},
        NativeTerrainPageKey{0, std::numeric_limits<std::int32_t>::min()},
        NativeTerrainPageKey{0, std::numeric_limits<std::int32_t>::max()},
        NativeTerrainPageKey{7669584, 0}, NativeTerrainPageKey{0, 7669584},
        NativeTerrainPageKey{-7669584, 0}, NativeTerrainPageKey{0, -7669584},
        NativeTerrainPageKey{7669583, 0}, NativeTerrainPageKey{0, 7669583},
        NativeTerrainPageKey{-7669583, 0}, NativeTerrainPageKey{0, -7669583}}) {
        VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::invalid_page, rejected_failure(request_for(page)));
    }
    auto count = request_for(); count.town_overrides.resize(10);
    VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::town_dependency_count, rejected_failure(std::move(count)));
    auto duplicate = request_for(); duplicate.town_overrides = {empty_town_override(0, 0), empty_town_override(0, 0)};
    VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::duplicate_town_region, rejected_failure(std::move(duplicate)));
    for (const NativeTerrainPageKey region : {
        NativeTerrainPageKey{-2, 0}, NativeTerrainPageKey{2, 0}, NativeTerrainPageKey{0, -2}, NativeTerrainPageKey{0, 2}}) {
        auto outside = request_for(); outside.town_overrides.push_back(empty_town_override(region.x, region.z));
        VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::town_dependency_scope, rejected_failure(std::move(outside)));
    }
    const auto zero = snapshot_for(request_for()); VWB_EXPECT(zero.town_overrides().empty());
    auto partial_request = request_for();
    partial_request.town_overrides = {empty_town_override(1, 1), town_override(-1, -1, 30, 12.0)};
    const auto partial = snapshot_for(std::move(partial_request));
    VWB_EXPECT_EQ(2U, static_cast<unsigned>(partial.town_overrides().size()));
    VWB_EXPECT_EQ(-1, partial.town_overrides()[0].region_x);
    VWB_EXPECT(!(NativeHorizontalRect{0, 0, 1, 1} == NativeHorizontalRect{1, 0, 1, 1}));
    VWB_EXPECT(!(NativeHorizontalRect{0, 0, 1, 1} == NativeHorizontalRect{0, 1, 1, 1}));
    VWB_EXPECT(!(NativeHorizontalRect{0, 0, 1, 1} == NativeHorizontalRect{0, 0, 2, 1}));
    VWB_EXPECT(!(NativeHorizontalRect{0, 0, 1, 1} == NativeHorizontalRect{0, 0, 1, 2}));
    VWB_EXPECT(!(NativeTerrainPageKey{0, 0} == NativeTerrainPageKey{1, 0}));
    VWB_EXPECT(!(NativeTerrainPageKey{0, 0} == NativeTerrainPageKey{0, 1}));
    auto edge_snapshot = [](const std::int32_t page_x) {
        auto edge = request_for({page_x, 0});
        for (std::int32_t z = -1; z <= 1; ++z) for (std::int32_t x = page_x - 1; x <= page_x + 1; ++x)
            edge.town_overrides.push_back(x == page_x && z == 0
                ? town_override(x, z, 152, 10.0) : empty_town_override(x, z));
        return snapshot_for(std::move(edge));
    };
    const auto low_edge = edge_snapshot(-7669582); const auto high_edge = edge_snapshot(7669582);
    VWB_EXPECT_EQ(-2147482960, low_edge.page_bounds().x); VWB_EXPECT_EQ(2147482960, high_edge.page_bounds().x);
    const auto flat = [](std::int32_t, std::int32_t) { return 10.0; };
    VWB_EXPECT(std::isfinite(low_edge.surface_y(low_edge.page_bounds().x + 153, 0, flat)));
    VWB_EXPECT(std::isfinite(high_edge.surface_y(high_edge.page_bounds().x + 153, 0, flat)));
}

VWB_TEST(native_shaping_page_rejects_each_noncanonical_explicit_town_field) {
    auto reject_town = [](NativeTownRegionOverride value, NativeTerrainPageKey page = {0, 0}) {
        auto request = request_for(page); request.town_overrides.push_back(std::move(value));
        VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::invalid_town, rejected_failure(std::move(request)));
    };
    auto value = town_override(0, 0, 30, 10.0); value.town.region_x = 9; reject_town(value);
    value = town_override(0, 0, 30, 10.0); value.town.region_z = 9; reject_town(value);
    value = town_override(0, 0, 30, 10.0); value.town.center_x += 1; reject_town(value);
    value = town_override(0, 0, 30, 10.0); value.town.center_z += 1; reject_town(value);
    reject_town(town_override(0, 0, 0, 10.0)); reject_town(town_override(0, 0, 153, 10.0));
    reject_town(town_override(0, 0, 30, std::numeric_limits<double>::infinity()));
}

VWB_TEST(native_shaping_page_town_dependencies_preserve_omission_empty_override_and_fallback_goldens) {
    const auto natural = [](std::int32_t, std::int32_t) { return 20.2; };
    const auto procedural = snapshot_for(request_for()); const auto forced = procedural.town_dependency(1, 0, natural);
    VWB_EXPECT(forced.has_value()); VWB_EXPECT_EQ(280, forced->center_x); VWB_EXPECT_EQ(0, forced->center_z);
    VWB_EXPECT_EQ(32, forced->radius_cells); VWB_EXPECT(near(20.25, forced->level_meters));
    auto suppress_request = request_for(); suppress_request.town_overrides = {empty_town_override(1, 0)};
    const auto suppressed = snapshot_for(std::move(suppress_request)); VWB_EXPECT(!suppressed.town_dependency(1, 0, natural).has_value());
    auto replace_request = request_for(); replace_request.town_overrides = {town_override(1, 0, 41, 19.0)};
    const auto replaced = snapshot_for(std::move(replace_request)); const auto replacement = replaced.town_dependency(1, 0, natural);
    VWB_EXPECT(replacement.has_value()); VWB_EXPECT_EQ(41, replacement->radius_cells); VWB_EXPECT_EQ(19.0, replacement->level_meters);
    VWB_EXPECT_THROW(std::invalid_argument, replaced.town_dependency(0, 0, {}));
    VWB_EXPECT_THROW(NativeTerrainShapingPageQueryError, replaced.town_dependency(-2, 0, natural));
    VWB_EXPECT_THROW(NativeTerrainShapingPageQueryError, replaced.town_dependency(2, 0, natural));
    VWB_EXPECT_THROW(NativeTerrainShapingPageQueryError, replaced.town_dependency(0, -2, natural));
    VWB_EXPECT_THROW(NativeTerrainShapingPageQueryError, replaced.town_dependency(0, 2, natural));
}

VWB_TEST(native_shaping_page_procedural_towns_cover_all_size_classes_absence_and_level_clamps) {
    bool absent = false; bool small = false; bool ordinary = false; bool large = false;
    const auto flat = [](std::int32_t, std::int32_t) { return 20.2; };
    for (std::int32_t region = -200; region <= 200; ++region) {
        const auto snapshot = snapshot_for(request_for({region, 2})); const auto town = snapshot.town_dependency(region, 2, flat);
        absent = absent || !town.has_value(); if (!town) continue;
        small = small || town->radius_cells < 30; ordinary = ordinary || (town->radius_cells >= 30 && town->radius_cells < 38);
        large = large || town->radius_cells >= 38;
    }
    VWB_EXPECT(absent && small && ordinary && large);
    const auto snapshot = snapshot_for(request_for());
    const auto minimum = snapshot.town_dependency(1, 0, [](std::int32_t, std::int32_t) { return -100.0; });
    const auto maximum = snapshot.town_dependency(1, 0, [](std::int32_t, std::int32_t) { return 100.0; });
    VWB_EXPECT(minimum.has_value() && near(minimum->level_meters, 14.1));
    VWB_EXPECT(maximum.has_value() && near(maximum->level_meters, 52.0));
    VWB_EXPECT_THROW(std::invalid_argument, snapshot.town_dependency(1, 0,
        [](std::int32_t, std::int32_t) { return std::numeric_limits<double>::quiet_NaN(); }));

}

VWB_TEST(native_shaping_page_rejects_each_noncanonical_site_scalar_rectangle_and_buffer) {
    auto reject_site = [](NativeSiteTerrainProfile value) {
        try { (void)admit_site(std::move(value)); VWB_EXPECT(false); }
        catch (const NativeTerrainShapingAdmissionError &error) {
            VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::invalid_site, error.failure());
        }
    };
    auto value = small_site("valid", 0, 0); value.version = 0; reject_site(value);
    value = small_site("valid", 0, 0); value.site_id.clear(); reject_site(value);
    value = small_site("valid", 0, 0); value.site_id.assign(NativeTerrainShapingSnapshot::MAX_SITE_ID_BYTES + 1, 'x'); reject_site(value);
    value = small_site("valid", 0, 0); value.source_signature.clear(); reject_site(value);
    value = small_site("valid", 0, 0); value.source_signature.assign(NativeTerrainShapingSnapshot::MAX_SOURCE_SIGNATURE_BYTES + 1, 'x'); reject_site(value);
    value = small_site("valid", 0, 0); value.site_id = std::string("\xC3\x28", 2); reject_site(value);
    value = small_site("valid", 0, 0); value.source_signature = std::string("\xC3\x28", 2); reject_site(value);
    value = small_site("valid", 0, 0); value.world_seed_utf8 = "wrong"; reject_site(value);
    value = small_site("valid", 0, 0); value.cell_size_meters = 1.0; reject_site(value);
    value = small_site("valid", 0, 0); value.level_meters = std::numeric_limits<double>::quiet_NaN(); reject_site(value);
    value = small_site("valid", 0, 0); value.reservation_cells.width = 0; reject_site(value);
    value = small_site("valid", 0, 0); value.origin.x = std::numeric_limits<float>::quiet_NaN(); reject_site(value);
    value = small_site("valid", 0, 0); value.origin.y = std::numeric_limits<float>::quiet_NaN(); reject_site(value);
    value = small_site("valid", 0, 0); value.origin.z = std::numeric_limits<float>::quiet_NaN(); reject_site(value);
    value = small_site("valid", 0, 0); value.origin.y += 0.001F; reject_site(value);
    value = small_site("valid", 0, 0); value.core_cells.width = 0; reject_site(value);
    value = small_site("valid", 0, 0); value.core_cells.depth = 0; reject_site(value);
    value = small_site("valid", 0, 0); value.core_cells.x = 1000001; reject_site(value);
    value = small_site("valid", 0, 0); value.core_cells.x = -1000001; reject_site(value);
    value = small_site("valid", 0, 0); value.core_cells.z = 1000001; reject_site(value);
    value = small_site("valid", 0, 0); value.core_cells.z = -1000001; reject_site(value);
    value = small_site("valid", 0, 0); value.core_cells = {999999, 1, 2, 1}; reject_site(value);
    value = small_site("valid", 0, 0); value.core_cells = {1, 999999, 1, 2}; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells.width = 0; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells.depth = 0; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells.x = 1000001; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells.x = -1000001; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells.z = 1000001; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells.z = -1000001; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells = {999999, 0, 2, 1}; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells = {0, 999999, 1, 2}; reject_site(value);
    value = small_site("valid", 0, 0); value.apron_cells = 0; reject_site(value);
    value = small_site("valid", 0, 0); value.apron_cells = 129; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells.x += 1; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells.z += 1; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells.width += 1; reject_site(value);
    value = small_site("valid", 0, 0); value.envelope_cells.depth += 1; reject_site(value);
    NativeSiteTerrainProfile too_large;
    too_large.world_seed_utf8 = "atlas-1492"; too_large.site_id = "large"; too_large.source_signature = "source";
    too_large.core_cells = {1, 1, 511, 511}; too_large.envelope_cells = {0, 0, 513, 513};
    too_large.reservation_cells = too_large.core_cells; too_large.origin = {1.35F, 1.0F, 1.35F};
    too_large.level_meters = 1.0; too_large.apron_cells = 1; too_large.ground_root_points.assign(4, too_large.origin);
    reject_site(too_large);
    value = small_site("valid", 0, 0); value.support_mask.pop_back(); reject_site(value);
    value = small_site("valid", 0, 0); value.distance_cells.pop_back(); reject_site(value);
    value = small_site("valid", 0, 0); value.support_mask[0] = 2; reject_site(value);
    value = small_site("valid", 0, 0); value.distance_cells[0] = std::numeric_limits<float>::quiet_NaN(); reject_site(value);
    value = small_site("valid", 0, 0); value.distance_cells[0] = -1.0F; reject_site(value);
    value = small_site("valid", 0, 0); value.support_mask[0] = 1; reject_site(value);
    value = small_site("valid", 0, 0); value.ground_root_points.clear(); reject_site(value);
    value = small_site("valid", 0, 0); value.ground_root_points.resize(NativeTerrainShapingSnapshot::MAX_GROUND_ROOT_POINTS + 1, value.origin); reject_site(value);
    value = small_site("valid", 0, 0); value.ground_root_points.push_back(value.origin); reject_site(value);
    value = small_site("valid", 0, 0); value.ground_root_points[0].x = std::numeric_limits<float>::quiet_NaN(); reject_site(value);
    value = small_site("valid", 0, 0); value.ground_root_points[0].y = std::numeric_limits<float>::quiet_NaN(); reject_site(value);
    value = small_site("valid", 0, 0); value.ground_root_points[0].z = std::numeric_limits<float>::quiet_NaN(); reject_site(value);
    value = small_site("valid", 0, 0); value.ground_root_points[0].y += 0.062F; reject_site(value);
    value = small_site("valid", 0, 0); value.ground_root_points[0].x = 0.0F; reject_site(value);
    value = small_site("valid", 0, 0); value.ground_root_points[0].x = 6.0F; reject_site(value);
    value = small_site("valid", 0, 0); value.ground_root_points[0].z = 0.0F; reject_site(value);
    value = small_site("valid", 0, 0); value.ground_root_points[0].z = 6.0F; reject_site(value);
}

VWB_TEST(native_shaping_page_rejects_duplicate_overlapping_and_nonintersecting_full_profiles) {
    auto too_many = request_for(); too_many.site_profiles.resize(NativeTerrainShapingSnapshot::PAGE_SAMPLE_CAPACITY + 1);
    VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::site_profile_count, rejected_failure(std::move(too_many)));
    auto null_handle = request_for(); null_handle.site_profiles.push_back({});
    VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::invalid_site, rejected_failure(std::move(null_handle)));
    auto foreign_definition = request_for(); foreign_definition.site_profiles = {admit_site(small_site("foreign", 0, 0))};
    try { (void)snapshot_for(std::move(foreign_definition), "atlas-1493"); VWB_EXPECT(false); }
    catch (const NativeTerrainShapingAdmissionError &error) {
        VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::invalid_site, error.failure());
    }
    auto duplicate = request_for(); duplicate.site_profiles = {admit_site(small_site("same", 0, 0)), admit_site(small_site("same", 20, 20))};
    VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::duplicate_site_id, rejected_failure(std::move(duplicate)));
    auto overlap = request_for(); overlap.site_profiles = {admit_site(small_site("a", 0, 0)), admit_site(small_site("b", 2, 2))};
    VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::overlapping_sites, rejected_failure(std::move(overlap)));
    auto outside = request_for(); outside.site_profiles = {admit_site(small_site("outside", 300, 300))};
    VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::site_outside_page, rejected_failure(std::move(outside)));
    auto outside_z = request_for(); outside_z.site_profiles = {admit_site(small_site("outside-z", 0, 300))};
    VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::site_outside_page, rejected_failure(std::move(outside_z)));

    auto large_profile = [](const std::string &id) {
        NativeSiteTerrainProfile site;
        site.world_seed_utf8 = "atlas-1492"; site.site_id = id; site.source_signature = "source:" + id;
        site.core_cells = {1, 1, 278, 278}; site.envelope_cells = {0, 0, 280, 280};
        site.reservation_cells = site.core_cells; site.origin = {2.7F, 5.0F, 2.7F};
        site.level_meters = 5.0; site.apron_cells = 1; site.ground_root_points.assign(4, site.origin);
        site.support_mask.assign(NativeTerrainShapingSnapshot::PAGE_SAMPLE_CAPACITY, 0);
        site.distance_cells.assign(NativeTerrainShapingSnapshot::PAGE_SAMPLE_CAPACITY, 1.0F);
        return site;
    };
    auto over_capacity = request_for(); over_capacity.site_profiles = {admit_site(large_profile("a")), admit_site(large_profile("b"))};
    VWB_EXPECT_EQ(NativeTerrainShapingAdmissionFailure::overlapping_sites, rejected_failure(std::move(over_capacity)));
    const std::vector<std::pair<NativeSiteTerrainProfile, NativeSiteTerrainProfile>> pairs = {
        {small_site("a", 0, 0), small_site("b", 5, 0)}, {small_site("a", 5, 0), small_site("b", 0, 0)},
        {small_site("a", 0, 0), small_site("b", 0, 5)}, {small_site("a", 0, 5), small_site("b", 0, 0)}};
    for (auto pair : pairs) {
        auto request = request_for(); request.site_profiles = {admit_site(std::move(pair.first)), admit_site(std::move(pair.second))};
        VWB_EXPECT_EQ(2U, static_cast<unsigned>(snapshot_for(std::move(request)).site_fragments().size()));
    }
}

VWB_TEST(native_shaping_page_crops_fully_validated_profiles_and_never_retains_more_than_one_page) {
    NativeSiteTerrainProfile full;
    full.world_seed_utf8 = "atlas-1492"; full.site_id = "full"; full.source_signature = "full-source";
    full.core_cells = {-99, -99, 510, 510}; full.envelope_cells = {-100, -100, 512, 512};
    full.reservation_cells = full.core_cells; full.origin = {0.0F, 17.0F, 0.0F};
    full.level_meters = 17.0; full.apron_cells = 1; full.ground_root_points.assign(4, full.origin);
    full.support_mask.assign(NativeTerrainShapingSnapshot::MAX_SITE_SAMPLES, 0);
    full.distance_cells.assign(NativeTerrainShapingSnapshot::MAX_SITE_SAMPLES, 1.0F);
    auto request = request_for(); request.site_profiles.push_back(admit_site(std::move(full)));
    const auto snapshot = snapshot_for(std::move(request));
    VWB_EXPECT_EQ(NativeTerrainShapingSnapshot::PAGE_SAMPLE_CAPACITY, snapshot.retained_site_samples());
    VWB_EXPECT_EQ(1U, static_cast<unsigned>(snapshot.site_fragments().size()));
    const auto &fragment = snapshot.site_fragments()[0];
    VWB_EXPECT_EQ((NativeHorizontalRect{0, 0, 280, 280}), fragment.cropped_cells);
    VWB_EXPECT_EQ(17.0, fragment.level_meters); VWB_EXPECT_EQ(1, fragment.apron_cells);
    VWB_EXPECT_EQ(NativeTerrainShapingSnapshot::PAGE_SAMPLE_CAPACITY, fragment.support_mask.size());
    VWB_EXPECT_EQ(NativeTerrainShapingSnapshot::PAGE_SAMPLE_CAPACITY, fragment.distance_cells.size());
}

VWB_TEST(native_shaping_page_fragments_retain_full_digest_and_row_major_crop) {
    NativeSiteTerrainProfile site;
    site.world_seed_utf8 = "atlas-1492"; site.site_id = "crop"; site.source_signature = "crop-source";
    site.core_cells = {0, 0, 3, 3}; site.envelope_cells = {-1, -1, 5, 5}; site.level_meters = 8.0; site.apron_cells = 1;
    site.reservation_cells = site.core_cells; site.origin = {0.0F, 8.0F, 0.0F}; site.ground_root_points.assign(4, site.origin);
    site.support_mask.assign(25, 0); site.support_mask[6] = 1;
    for (std::uint8_t index = 0; index < 25; ++index) site.distance_cells.push_back(index == 6 ? 0.0F : static_cast<float>(index + 1));
    auto first_request = request_for(); first_request.site_profiles = {admit_site(site)}; const auto first = snapshot_for(std::move(first_request));
    const auto &fragment = first.site_fragments()[0];
    VWB_EXPECT_EQ((NativeHorizontalRect{0, 0, 4, 4}), fragment.cropped_cells); VWB_EXPECT_EQ(16U, static_cast<unsigned>(fragment.support_mask.size()));
    VWB_EXPECT_EQ(0.0F, fragment.distance_cells.front()); VWB_EXPECT_EQ(25.0F, fragment.distance_cells.back());
    auto outside_only = site; outside_only.distance_cells[0] += 0.5F;
    auto outside_request = request_for(); outside_request.site_profiles = {admit_site(outside_only)}; const auto outside = snapshot_for(std::move(outside_request));
    VWB_EXPECT_EQ(fragment.distance_cells, outside.site_fragments()[0].distance_cells);
    VWB_EXPECT(!(fragment.full_profile_digest == outside.site_fragments()[0].full_profile_digest));
    VWB_EXPECT_EQ(first.physical_content_identity(), outside.physical_content_identity());
    auto inside = site; inside.distance_cells[7] += 0.5F;
    auto inside_request = request_for(); inside_request.site_profiles = {admit_site(inside)}; const auto changed = snapshot_for(std::move(inside_request));
    VWB_EXPECT(!(fragment.distance_cells == changed.site_fragments()[0].distance_cells));
    VWB_EXPECT(!(first.physical_content_identity() == changed.physical_content_identity()));

    const auto original_handle = admit_site(site);
    auto provenance_only = site; provenance_only.reservation_cells.width = 2;
    provenance_only.origin.x += 0.25F; provenance_only.ground_root_points[0].x += 0.25F;
    const auto provenance_handle = admit_site(provenance_only);
    VWB_EXPECT(!(original_handle->full_profile_digest() == provenance_handle->full_profile_digest()));
    auto provenance_request = request_for(); provenance_request.site_profiles = {provenance_handle};
    VWB_EXPECT_EQ(first.physical_content_identity(), snapshot_for(std::move(provenance_request)).physical_content_identity());
}

VWB_TEST(native_shaping_page_identity_is_canonical_content_local_and_binds_exact_dependencies) {
    auto forwards = request_for({0, 0}, 7);
    forwards.town_overrides = {town_override(1, 0, 31, 18.0), empty_town_override(-1, 1)};
    forwards.site_profiles = {admit_site(small_site("z-site", 20, 20)), admit_site(small_site("a-site", 0, 0))};
    auto backwards = forwards; std::reverse(backwards.town_overrides.begin(), backwards.town_overrides.end());
    std::reverse(backwards.site_profiles.begin(), backwards.site_profiles.end());
    const auto first = snapshot_for(std::move(forwards)); const auto second = snapshot_for(std::move(backwards));
    VWB_EXPECT_EQ(first.physical_content_identity(), second.physical_content_identity());
    VWB_EXPECT_EQ(50U, static_cast<unsigned>(first.retained_site_samples())); VWB_EXPECT_EQ(7U, static_cast<unsigned>(first.generation_revision()));
    VWB_EXPECT_EQ((NativeTerrainPageKey{0, 0}), first.page_key()); VWB_EXPECT_EQ((NativeHorizontalRect{0, 0, 280, 280}), first.page_bounds());
    VWB_EXPECT_EQ(first.definition().physical_content_identity(), shaping_definition().physical_content_identity());
    auto revision_request = request_for({0, 0}, 8); revision_request.town_overrides = first.town_overrides();
    revision_request.site_profiles = {admit_site(small_site("a-site", 0, 0)), admit_site(small_site("z-site", 20, 20))};
    const auto revision = snapshot_for(std::move(revision_request));
    VWB_EXPECT_EQ(8U, static_cast<unsigned>(revision.generation_revision()));
    VWB_EXPECT_EQ(first.physical_content_identity(), revision.physical_content_identity());
    auto omitted = request_for({0, 0}, 7); omitted.town_overrides = {town_override(1, 0, 31, 18.0)};
    omitted.site_profiles = {admit_site(small_site("a-site", 0, 0)), admit_site(small_site("z-site", 20, 20))};
    VWB_EXPECT(!(first.physical_content_identity() == snapshot_for(std::move(omitted)).physical_content_identity()));
    auto changed_town = request_for({0, 0}, 7); changed_town.town_overrides = first.town_overrides();
    changed_town.town_overrides[1].town.level_meters += 1.0;
    changed_town.site_profiles = {admit_site(small_site("a-site", 0, 0)), admit_site(small_site("z-site", 20, 20))};
    VWB_EXPECT(!(first.physical_content_identity() == snapshot_for(std::move(changed_town)).physical_content_identity()));
    VWB_EXPECT(!(snapshot_for(request_for()).physical_content_identity() == snapshot_for(request_for({1, 0})).physical_content_identity()));
    VWB_EXPECT(!(snapshot_for(request_for()).physical_content_identity() == snapshot_for(request_for(), "atlas-1493").physical_content_identity()));
}

VWB_TEST(native_shaping_page_queries_fail_closed_outside_owner_bounds) {
    auto request = request_for(); suppress_all_towns(request); request.site_profiles = {admit_site(small_site("site", 0, 0))};
    const auto snapshot = snapshot_for(std::move(request)); const auto flat = [](std::int32_t, std::int32_t) { return 13.0; };
    VWB_EXPECT(snapshot.owns_cell(0, 0)); VWB_EXPECT(snapshot.owns_cell(279, 279));
    VWB_EXPECT(!snapshot.owns_cell(-1, 0)); VWB_EXPECT(!snapshot.owns_cell(280, 0));
    VWB_EXPECT(!snapshot.owns_cell(0, -1)); VWB_EXPECT(!snapshot.owns_cell(0, 280));
    for (const NativeTerrainPageKey cell : {NativeTerrainPageKey{-1, 0}, NativeTerrainPageKey{280, 0},
        NativeTerrainPageKey{0, -1}, NativeTerrainPageKey{0, 280}}) {
        VWB_EXPECT_THROW(NativeTerrainShapingPageQueryError, snapshot.town_region_at_cell(cell.x, cell.z, flat));
        VWB_EXPECT_THROW(NativeTerrainShapingPageQueryError, snapshot.town_region_for_surface_cell(cell.x, cell.z, flat));
        VWB_EXPECT_THROW(NativeTerrainShapingPageQueryError, snapshot.surface_y(cell.x, cell.z, flat));
        VWB_EXPECT_THROW(NativeTerrainShapingPageQueryError, snapshot.town_core_contains(cell.x, cell.z, flat));
        VWB_EXPECT_THROW(NativeTerrainShapingPageQueryError, snapshot.site_core_contains(cell.x, cell.z));
        VWB_EXPECT_THROW(NativeTerrainShapingPageQueryError, snapshot.protects_minimum_overburden(cell.x, cell.z, flat));
    }
}

VWB_TEST(native_shaping_page_preserves_town_scan_order_strict_tie_and_apron_precedence) {
    const auto natural = [](std::int32_t x, std::int32_t) { return 100.0 + x * 0.01; };
    auto request = request_for(); request.town_overrides = {town_override(1, 0, 152, 20.0), town_override(0, 0, 152, 10.0)};
    const auto snapshot = snapshot_for(std::move(request));
    const auto tie = snapshot.town_region_at_cell(140, 0, natural); VWB_EXPECT(tie.has_value()); VWB_EXPECT_EQ(0, tie->region_x);
    const auto surface_tie = snapshot.town_region_for_surface_cell(140, 0, natural);
    VWB_EXPECT(surface_tie.has_value()); VWB_EXPECT_EQ(0, surface_tie->region_x);

    auto apron_request = request_for(); apron_request.town_overrides = {town_override(0, 0, 30, 10.0)};
    apron_request.site_profiles = {admit_site(small_site("under-town-apron", 39, 0, 1.0))};
    const auto apron = snapshot_for(std::move(apron_request));
    VWB_EXPECT(near(10.0, apron.surface_y(0, 0, natural))); VWB_EXPECT(apron.town_core_contains(30, 0, natural));
    VWB_EXPECT(!apron.town_core_contains(40, 0, natural)); VWB_EXPECT(apron.protects_minimum_overburden(40, 0, natural));
    const double shaped = apron.surface_y(40, 0, natural);
    VWB_EXPECT(shaped > 10.0); VWB_EXPECT(shaped < 100.4); VWB_EXPECT(!near(shaped, 1.0));
}

VWB_TEST(native_shaping_page_uses_site_distance_smoothstep_and_support_only_for_core_protection) {
    const auto natural = [](std::int32_t, std::int32_t) { return 13.0; };
    auto request = request_for(); suppress_all_towns(request); request.site_profiles = {admit_site(small_site("site", 0, 0, 5.0))};
    const auto snapshot = snapshot_for(std::move(request));
    VWB_EXPECT(near(5.0, snapshot.surface_y(1, 1, natural))); VWB_EXPECT(near(13.0, snapshot.surface_y(1, 0, natural)));
    VWB_EXPECT(snapshot.site_core_contains(1, 1)); VWB_EXPECT(!snapshot.site_core_contains(1, 0));
    VWB_EXPECT(snapshot.protects_minimum_overburden(1, 1, natural)); VWB_EXPECT(!snapshot.protects_minimum_overburden(1, 0, natural));
    VWB_EXPECT(!snapshot.town_core_contains(1, 1, natural)); VWB_EXPECT(near(13.0, snapshot.surface_y(20, 20, natural)));
    VWB_EXPECT(!snapshot.site_core_contains(20, 20));
}

VWB_TEST(native_shaping_page_fails_closed_on_missing_nonfinite_and_out_of_domain_natural_samples) {
    auto empty_request = request_for(); suppress_all_towns(empty_request); const auto empty = snapshot_for(std::move(empty_request));
    VWB_EXPECT_THROW(std::invalid_argument, empty.surface_y(0, 0, {}));
    VWB_EXPECT_THROW(std::invalid_argument, empty.surface_y(0, 0,
        [](std::int32_t, std::int32_t) { return std::numeric_limits<double>::quiet_NaN(); }));
    const auto flat = [](std::int32_t, std::int32_t) { return 10.0; };
    const NativeTownTerrainProfile high{0, 0, std::numeric_limits<std::int32_t>::max() - 4, 0, 30, 10.0};
    const NativeTownTerrainProfile low{0, 0, std::numeric_limits<std::int32_t>::min() + 4, 0, 30, 10.0};
    VWB_EXPECT_THROW(std::out_of_range, empty.town_slope_apron_cells(high, flat));
    VWB_EXPECT_THROW(std::out_of_range, empty.town_slope_apron_cells(low, flat));
    VWB_EXPECT_THROW(std::invalid_argument, empty.town_slope_apron_cells(high, {}));
    VWB_EXPECT_THROW(std::out_of_range, empty.town_slope_apron_cells(
        NativeTownTerrainProfile{0, 0, 0, 0, 30, 10.0},
        [](std::int32_t, std::int32_t) { return std::numeric_limits<double>::max(); }));
    VWB_EXPECT_THROW(std::out_of_range, empty.town_slope_apron_cells(
        NativeTownTerrainProfile{0, 0, 0, 0, 30, 10.0},
        [](std::int32_t, std::int32_t) { return 1.0e20; }));
    auto town_request = request_for(); town_request.town_overrides = {town_override(0, 0, 30, 10.0)};
    const auto town = snapshot_for(std::move(town_request));
    const auto apron_invalid = [](std::int32_t x, std::int32_t z) {
        return x == 48 && z == 0 ? std::numeric_limits<double>::quiet_NaN() : 10.0;
    };
    VWB_EXPECT_THROW(std::invalid_argument, town.town_slope_apron_cells(town_override(0, 0, 30, 10.0).town, apron_invalid));
    const auto outer_invalid = [](std::int32_t x, std::int32_t z) {
        return x == 47 && z == 12 ? std::numeric_limits<double>::quiet_NaN() : 10.0;
    };
    VWB_EXPECT_THROW(std::invalid_argument, town.surface_y(40, 10, outer_invalid));
}

VWB_TEST(native_shaping_page_promotes_float32_directions_for_binary64_scalar_sampling) {
    auto request = request_for();
    for (std::int32_t z = -1; z <= 1; ++z) {
        for (std::int32_t x = -1; x <= 1; ++x) {
            request.town_overrides.push_back(x == 1 && z == 0
                ? town_override(1, 0, 30, 10.0) : empty_town_override(x, z));
        }
    }
    const auto snapshot = snapshot_for(std::move(request));
    std::vector<std::pair<std::int32_t, std::int32_t>> samples;
    const auto natural = [&](const std::int32_t x, const std::int32_t z) {
        samples.emplace_back(x, z);
        return x == 148 && z == 12 ? 50.0 : 78.0;
    };
    const double shaped = snapshot.surface_y(165, 10, natural);
    VWB_EXPECT(std::isfinite(shaped));
    VWB_EXPECT(std::find(samples.begin(), samples.end(), std::pair<std::int32_t, std::int32_t>{148, 12}) != samples.end());
    VWB_EXPECT(std::find(samples.begin(), samples.end(), std::pair<std::int32_t, std::int32_t>{147, 12}) == samples.end());

    samples.clear();
    const NativeTownTerrainProfile diagonal_town{0, 0, 0, 0, 30, 10.0};
    VWB_EXPECT_EQ(18, snapshot.town_slope_apron_cells(diagonal_town,
        [&](const std::int32_t x, const std::int32_t z) { samples.emplace_back(x, z); return 10.0; }));
    for (const auto expected : {
        std::pair<std::int32_t, std::int32_t>{34, 34}, {-34, 34}, {34, -34}, {-34, -34}}) {
        VWB_EXPECT(std::find(samples.begin(), samples.end(), expected) != samples.end());
    }
}
