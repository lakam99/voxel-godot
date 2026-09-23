#include "test_harness.hpp"

#include "../core/native_multi_page_voxel_block.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

using namespace voxel::world_backend;

namespace {

WorldSourceDefinition definition(const std::string &seed = "multi-page-voxel") {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
    descriptor.constants.minimum_surface_meters = 13.0;
    descriptor.constants.maximum_surface_meters = 13.0;
    return WorldSourceDefinition(std::move(descriptor));
}

std::vector<NativeTownRegionOverride> absent_towns(const NativeTerrainPageKey page) {
    std::vector<NativeTownRegionOverride> result;
    for (std::int32_t z = page.z - 1; z <= page.z + 1; ++z)
        for (std::int32_t x = page.x - 1; x <= page.x + 1; ++x)
            result.push_back({x, z, false, {}});
    return result;
}

std::int32_t floor_page(const std::int32_t cell) {
    return cell / 280 - static_cast<std::int32_t>(cell % 280 < 0);
}

std::vector<NativeTerrainPageKey> required_for(
    const WorldSourceDefinition &source, const NativeEffectiveVoxelBlockRequest &request) {
    std::vector<NativeTerrainPageKey> required;
    const std::int64_t scale = std::int64_t{1} << request.lod;
    for (std::int32_t z = 0; z < request.size.z; ++z)
        for (std::int32_t x = 0; x < request.size.x; ++x) {
            const NativeTerrainPageKey primary{
                floor_page(static_cast<std::int32_t>(request.origin.x + x * scale)),
                floor_page(static_cast<std::int32_t>(request.origin.z + z * scale))};
            const auto pages = world_effective_shaping_dependencies(source, primary);
            required.insert(required.end(), pages.begin(), pages.end());
        }
    std::sort(required.begin(), required.end(), [](const auto a, const auto b) {
        return a.z < b.z || (a.z == b.z && a.x < b.x);
    });
    required.erase(std::unique(required.begin(), required.end()), required.end());
    return required;
}

struct Fixture {
    WorldSourceDefinition source;
    WorldDeltaStore store;
    NativeSiteSourcePolicy policy;
    NativeTerrainShapingRegistry registry;

    explicit Fixture(const std::string &seed = "multi-page-voxel") : source(definition(seed)), policy([] {
        NativeSiteSourcePolicy value;
        value.engine_version_utf8 = "4.6.1.stable.official.14d19694e";
        value.ordinary_region_cells = 140;
        value.ordinary_spawn_chance = 0.08;
        return value;
    }()), registry(source, policy) {}

    std::vector<NativeTerrainShapingPagePin> pins(
        const NativeEffectiveVoxelBlockRequest &request) {
        const auto pages = required_for(source, request);
        std::vector<NativeSiteSourceRegionKey> unresolved;
        for (const auto page : pages) {
            const auto provisional = registry.pin_page(page, absent_towns(page));
            for (const auto region : provisional.unresolved_dependencies())
                if (std::find(unresolved.begin(), unresolved.end(), region) == unresolved.end())
                    unresolved.push_back(region);
        }
        NativeTerrainShapingRegistryBatch resolutions;
        resolutions.expected_revision = registry.revision();
        for (const auto region : unresolved) {
            NativeSiteSourceResolution resolution;
            resolution.region = region;
            resolution.request_identity = registry.source_request_identity(region);
            resolution.worker_source_key.assign(64, 'b');
            resolution.kind = NativeSiteSourceResolutionKind::absent;
            resolution.reason_code = "ordinary_structure_overlap";
            resolutions.resolutions.push_back(std::move(resolution));
        }
        if (!resolutions.resolutions.empty()) static_cast<void>(registry.apply(resolutions));
        std::vector<NativeTerrainShapingPagePin> result;
        for (const auto page : pages) result.push_back(registry.pin_page(page, absent_towns(page)));
        return result;
    }
};

NativeCellState durable_edit(const CellCoord cell, const TerrainMaterialId material) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = material;
    input.biome = TerrainBiomeId::plains;
    input.solid = true;
    input.density = 1.35;
    input.metadata = NativeValue::object({
        {"source", NativeValue::string("terrain_edit")},
        {"terrainMeshAffects", NativeValue::boolean(true)},
    });
    input.block_id = NativeBlockIdentity::create("multi-page:" + std::to_string(cell.x)
        + ":" + std::to_string(cell.y) + ":" + std::to_string(cell.z));
    input.edit_reason = "multi-page-test";
    input.generated = false;
    input.edited = true;
    return make_native_cell_state(input, NativeCellStateNamespace::durable_terrain);
}

void check_against_page_samples(Fixture &fixture, const NativeEffectiveVoxelBlockRequest request) {
    const auto pages = fixture.pins(request);
    const auto deltas = fixture.store.pin();
    const auto block = encode_native_multi_page_voxel_block(fixture.source, deltas, pages, request);
    const auto again = encode_native_multi_page_voxel_block(fixture.source, deltas, pages, request);
    VWB_EXPECT_EQ(block.pin_identity.digest, again.pin_identity.digest);
    VWB_EXPECT_EQ(block.block_content_identity, again.block_content_identity);
    const std::int64_t scale = std::int64_t{1} << request.lod;
    for (std::int32_t z = 0; z < request.size.z; ++z)
        for (std::int32_t x = 0; x < request.size.x; ++x) {
            const std::int32_t cx = static_cast<std::int32_t>(request.origin.x + x * scale);
            const std::int32_t cz = static_cast<std::int32_t>(request.origin.z + z * scale);
            const NativeTerrainPageKey primary{floor_page(cx), floor_page(cz)};
            const auto dependencies = world_effective_shaping_dependencies(fixture.source, primary);
            std::vector<NativeTerrainShapingPagePin> local;
            for (const auto dependency : dependencies) {
                const auto found = std::find_if(pages.begin(), pages.end(), [&](const auto &page) {
                    return page.page_key() == dependency;
                });
                VWB_EXPECT(found != pages.end());
                local.push_back(*found);
            }
            const NativeEffectiveTerrainSource source(
                WorldSourcePin(fixture.source, deltas, primary, local));
            const auto one = encode_native_effective_voxel_block(source,
                {{cx, request.origin.y, cz}, {1, request.size.y, 1}, request.lod});
            for (std::int32_t y = 0; y < request.size.y; ++y) {
                const std::size_t index = static_cast<std::size_t>(y)
                    + static_cast<std::size_t>(request.size.y) * (static_cast<std::size_t>(x)
                    + static_cast<std::size_t>(request.size.x) * static_cast<std::size_t>(z));
                VWB_EXPECT_EQ(one.sdf16_le[2U * static_cast<std::size_t>(y)], block.sdf16_le[2U * index]);
                VWB_EXPECT_EQ(one.sdf16_le[2U * static_cast<std::size_t>(y) + 1U], block.sdf16_le[2U * index + 1U]);
                VWB_EXPECT_EQ(one.indices8[static_cast<std::size_t>(y)], block.indices8[index]);
                VWB_EXPECT_EQ(one.data5_8[static_cast<std::size_t>(y)], block.data5_8[index]);
            }
        }
}

} // namespace

VWB_TEST(native_multi_page_voxel_negative_both_axes_stitches_zxy) {
    Fixture fixture;
    check_against_page_samples(fixture, {{-2, -1, -2}, {4, 3, 4}, 0});
}

VWB_TEST(native_multi_page_voxel_single_page_content_matches_single_page_encoder) {
    Fixture fixture;
    const NativeEffectiveVoxelBlockRequest request{{0, 0, 0}, {2, 2, 2}, 0};
    const auto deltas = fixture.store.pin();
    const auto pages = fixture.pins(request);
    const auto composite = encode_native_multi_page_voxel_block(
        fixture.source, deltas, pages, request);
    const NativeEffectiveTerrainSource source(
        WorldSourcePin(fixture.source, deltas, {0, 0}, pages));
    const auto single = encode_native_effective_voxel_block(source, request);
    VWB_EXPECT_EQ(single.block_content_identity, composite.block_content_identity);
    VWB_EXPECT_EQ(single.sdf16_le, composite.sdf16_le);
    VWB_EXPECT_EQ(single.indices8, composite.indices8);
    VWB_EXPECT_EQ(single.data5_8, composite.data5_8);
}

VWB_TEST(native_multi_page_voxel_positive_boundary_stitches_zxy) {
    Fixture fixture;
    check_against_page_samples(fixture, {{278, -1, 278}, {4, 2, 4}, 0});
}

VWB_TEST(native_multi_page_voxel_lod_skips_primary_pages) {
    Fixture fixture;
    check_against_page_samples(fixture, {{-281, 0, -281}, {3, 1, 3}, 10});
}

VWB_TEST(native_multi_page_voxel_rejects_invalid_dimensions_lod_and_overflow) {
    Fixture fixture;
    const auto deltas = fixture.store.pin();
    const NativeEffectiveVoxelBlockRequest valid{{0, 0, 0}, {1, 1, 1}, 0};
    const auto pages = fixture.pins(valid);
    for (std::int32_t axis = 0; axis < 3; ++axis) {
        auto invalid = valid;
        if (axis == 0) invalid.size.x = 0;
        if (axis == 1) invalid.size.y = 0;
        if (axis == 2) invalid.size.z = 0;
        VWB_EXPECT_THROW(std::invalid_argument,
            encode_native_multi_page_voxel_block(fixture.source, deltas, pages, invalid));
    }
    for (std::int32_t axis = 0; axis < 3; ++axis) {
        auto invalid = valid;
        if (axis == 0) invalid.size.x = 33;
        if (axis == 1) invalid.size.y = 33;
        if (axis == 2) invalid.size.z = 33;
        VWB_EXPECT_THROW(std::invalid_argument,
            encode_native_multi_page_voxel_block(fixture.source, deltas, pages, invalid));
    }
    auto invalid = valid;
    invalid.lod = 25;
    VWB_EXPECT_THROW(std::invalid_argument,
        encode_native_multi_page_voxel_block(fixture.source, deltas, pages, invalid));
    invalid = valid;
    invalid.origin.y = std::numeric_limits<std::int32_t>::max();
    invalid.size.y = 2;
    VWB_EXPECT_THROW(std::out_of_range,
        encode_native_multi_page_voxel_block(fixture.source, deltas, pages, invalid));
}

VWB_TEST(native_multi_page_voxel_seam_edits_share_one_delta_snapshot) {
    Fixture fixture;
    const NativeEffectiveVoxelBlockRequest request{{-1, 0, -1}, {2, 1, 2}, 0};
    const auto pages = fixture.pins(request);
    const auto before = fixture.store.pin();
    const auto old_block = encode_native_multi_page_voxel_block(fixture.source, before, pages, request);
    WorldTypedStateAdmission admission;
    admission.transaction_id = "multi-page:seam-edits";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({
        {NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable,
            durable_edit({-1, 0, -1}, TerrainMaterialId::copper_ore)},
        {NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable,
            durable_edit({0, 0, 0}, TerrainMaterialId::iron_ore)},
    });
    static_cast<void>(fixture.store.admit_typed_state(admission));
    const auto after = fixture.store.pin();
    const auto new_block = encode_native_multi_page_voxel_block(fixture.source, after, pages, request);
    VWB_EXPECT(old_block.pin_identity.digest != new_block.pin_identity.digest);
    VWB_EXPECT(old_block.block_content_identity.digest != new_block.block_content_identity.digest);
    VWB_EXPECT_EQ(before.revision(), old_block.terrain_delta_revision);
    VWB_EXPECT_EQ(after.revision(), new_block.terrain_delta_revision);
    VWB_EXPECT_EQ(13U, new_block.indices8[0]);
    VWB_EXPECT_EQ(11U, new_block.indices8[3]);
    check_against_page_samples(fixture, request);
}

VWB_TEST(native_multi_page_voxel_content_identity_ignores_unrelated_delta_revision) {
    Fixture fixture;
    const NativeEffectiveVoxelBlockRequest request{{-1, 0, -1}, {2, 1, 2}, 0};
    const auto pages = fixture.pins(request);
    const auto before = encode_native_multi_page_voxel_block(
        fixture.source, fixture.store.pin(), pages, request);
    WorldTypedStateAdmission admission;
    admission.transaction_id = "multi-page:remote-edit";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({
        {NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable,
            durable_edit({10000, 0, 10000}, TerrainMaterialId::copper_ore)},
    });
    static_cast<void>(fixture.store.admit_typed_state(admission));
    const auto after = encode_native_multi_page_voxel_block(
        fixture.source, fixture.store.pin(), pages, request);
    VWB_EXPECT(before.pin_identity.digest != after.pin_identity.digest);
    VWB_EXPECT_EQ(before.block_content_identity, after.block_content_identity);
    VWB_EXPECT_EQ(before.sdf16_le, after.sdf16_le);
    VWB_EXPECT_EQ(before.indices8, after.indices8);
    VWB_EXPECT_EQ(before.data5_8, after.data5_8);
}

VWB_TEST(native_multi_page_voxel_content_identity_conservatively_tracks_dependency_page) {
    Fixture fixture;
    const NativeEffectiveVoxelBlockRequest request{{0, 0, 0}, {2, 1, 2}, 0};
    const auto pages = fixture.pins(request);
    const auto before = encode_native_multi_page_voxel_block(
        fixture.source, fixture.store.pin(), pages, request);
    WorldTypedStateAdmission admission;
    admission.transaction_id = "multi-page:same-page-outside-block";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({
        {NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable,
            durable_edit({100, 0, 100}, TerrainMaterialId::copper_ore)},
    });
    static_cast<void>(fixture.store.admit_typed_state(admission));
    const auto after = encode_native_multi_page_voxel_block(
        fixture.source, fixture.store.pin(), pages, request);
    VWB_EXPECT(before.block_content_identity.digest != after.block_content_identity.digest);
    VWB_EXPECT_EQ(before.sdf16_le, after.sdf16_le);
    VWB_EXPECT_EQ(before.indices8, after.indices8);
    VWB_EXPECT_EQ(before.data5_8, after.data5_8);
}

VWB_TEST(native_multi_page_voxel_rejects_missing_or_mixed_shaping) {
    Fixture fixture;
    const NativeEffectiveVoxelBlockRequest request{{-1, 0, -1}, {2, 1, 2}, 0};
    auto pages = fixture.pins(request);
    const auto deltas = fixture.store.pin();
    const auto complete = pages;
    pages.clear();
    VWB_EXPECT_THROW(std::invalid_argument,
        encode_native_multi_page_voxel_block(fixture.source, deltas, pages, request));
    pages = complete;
    pages.pop_back();
    VWB_EXPECT_THROW(std::invalid_argument,
        encode_native_multi_page_voxel_block(fixture.source, deltas, pages, request));
    pages = complete;
    pages.push_back(pages.front());
    VWB_EXPECT_THROW(std::invalid_argument,
        encode_native_multi_page_voxel_block(fixture.source, deltas, pages, request));
    pages = complete;
    pages.front() = pages.back();
    VWB_EXPECT_THROW(std::invalid_argument,
        encode_native_multi_page_voxel_block(fixture.source, deltas, pages, request));
    pages = complete;
    const auto extra_page = fixture.pins({{560, 0, 560}, {1, 1, 1}, 0});
    const auto expected = required_for(fixture.source, request);
    const auto extra = std::find_if(extra_page.begin(), extra_page.end(), [&](const auto &page) {
        return std::find(expected.begin(), expected.end(), page.page_key()) == expected.end();
    });
    VWB_EXPECT(extra != extra_page.end());
    pages.push_back(*extra);
    VWB_EXPECT_THROW(std::invalid_argument,
        encode_native_multi_page_voxel_block(fixture.source, deltas, pages, request));
    pages = fixture.pins(request);
    // A different admitted registry policy has the same source definition and
    // can produce a ready page, but its content identity is not co-admissible.
    NativeSiteSourcePolicy alternate_policy = fixture.policy;
    alternate_policy.engine_version_utf8 = "4.6.1.stable.official.14d19694e-alternate";
    NativeTerrainShapingRegistry alternate(fixture.source, alternate_policy);
    const NativeTerrainPageKey key = pages.front().page_key();
    const auto foreign_page = alternate.pin_page(key, absent_towns(key));
    VWB_EXPECT(foreign_page.readiness() == NativeTerrainShapingPageReadiness::ready);
    VWB_EXPECT(!(foreign_page.registry_content_identity() == pages.front().registry_content_identity()));
    pages.front() = foreign_page;
    VWB_EXPECT_THROW(std::invalid_argument,
        encode_native_multi_page_voxel_block(fixture.source, deltas, pages, request));

    pages = fixture.pins(request);
    const auto old_page = pages.front();
    NativeTerrainShapingRegistryBatch mutation;
    mutation.expected_revision = fixture.registry.revision();
    for (std::int32_t z = -32; z <= 32 && mutation.resolutions.empty(); ++z)
        for (std::int32_t x = -32; x <= 32 && mutation.resolutions.empty(); ++x) {
            const NativeSiteSourceRegionKey region{x, z};
            if (!native_site_source_candidate_for_region(fixture.source, region)) continue;
            NativeSiteSourceResolution resolution;
            resolution.region = region;
            resolution.request_identity = fixture.registry.source_request_identity(region);
            resolution.worker_source_key.assign(64, 'b');
            resolution.kind = NativeSiteSourceResolutionKind::absent;
            resolution.reason_code = "ordinary_structure_overlap";
            mutation.resolutions.push_back(std::move(resolution));
        }
    VWB_EXPECT(!mutation.resolutions.empty());
    static_cast<void>(fixture.registry.apply(mutation));
    pages = fixture.pins(request);
    VWB_EXPECT(old_page.registry_revision() != pages.front().registry_revision());
    pages.front() = old_page;
    VWB_EXPECT_THROW(std::invalid_argument,
        encode_native_multi_page_voxel_block(fixture.source, deltas, pages, request));
}

VWB_TEST(native_multi_page_voxel_rejects_pending_and_foreign_source_page) {
    Fixture fixture("atlas");
    NativeTerrainShapingRegistry unresolved(fixture.source, fixture.policy);
    NativeEffectiveVoxelBlockRequest request{{0, 0, 0}, {1, 1, 1}, 0};
    bool found_pending = false;
    NativeTerrainShapingPagePin pending;
    for (std::int32_t z = -32; z <= 32 && !found_pending; ++z)
        for (std::int32_t x = -32; x <= 32 && !found_pending; ++x) {
            const auto candidate = native_site_source_candidate_for_region(fixture.source, {x, z});
            if (!candidate) continue;
            const NativeTerrainPageKey page_key{
                floor_page(candidate->center_x), floor_page(candidate->center_z)};
            const auto page = unresolved.pin_page(page_key, absent_towns(page_key));
            if (page.readiness() == NativeTerrainShapingPageReadiness::ready) continue;
            request.origin = {page_key.x * 280, 0, page_key.z * 280};
            pending = page;
            found_pending = true;
        }
    VWB_EXPECT(found_pending);
    auto pages = fixture.pins(request);
    const auto deltas = fixture.store.pin();
    const auto ready = pages;
    const auto pending_target = std::find_if(pages.begin(), pages.end(), [&](const auto &page) {
        return page.page_key() == pending.page_key();
    });
    VWB_EXPECT(pending_target != pages.end());
    *pending_target = pending;
    VWB_EXPECT_THROW(std::invalid_argument,
        encode_native_multi_page_voxel_block(fixture.source, deltas, pages, request));

    pages = ready;
    Fixture foreign("foreign-multi-page-voxel");
    const auto foreign_pages = foreign.pins(request);
    const auto foreign_page = std::find_if(foreign_pages.begin(), foreign_pages.end(), [&](const auto &page) {
        return page.page_key() == pages.front().page_key();
    });
    VWB_EXPECT(foreign_page != foreign_pages.end());
    pages.front() = *foreign_page;
    VWB_EXPECT_THROW(std::invalid_argument,
        encode_native_multi_page_voxel_block(fixture.source, deltas, pages, request));
}
