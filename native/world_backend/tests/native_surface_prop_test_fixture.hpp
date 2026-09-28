#pragma once

#include "../core/native_effective_terrain_source.hpp"
#include "../core/native_surface_prop_rng_trace.hpp"
#include "../core/native_terrain_shaping_registry.hpp"

#include <algorithm>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace voxel::world_backend::surface_prop_test_fixture {

inline WorldSourceDefinition definition(const std::string &seed = "placement-set") {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
    descriptor.revisions.terrain_generator_revision = 8U;
    descriptor.revisions.lattice_query_revision = 6U;
    descriptor.revisions.cell_center_query_revision = 7U;
    descriptor.revisions.surface_column_query_revision = 8U;
    return WorldSourceDefinition(std::move(descriptor));
}

inline WorldDeltaPinnedSnapshot empty_deltas() { return WorldDeltaStore().pin(); }

inline WorldSourcePin ready_pin(
    const WorldSourceDefinition &source, NativeTerrainPageKey primary,
    const WorldDeltaPinnedSnapshot &deltas) {
    NativeSiteSourcePolicy policy;
    policy.engine_version_utf8 = "4.6.1.stable.official.14d19694e";
    policy.ordinary_region_cells = 140;
    policy.ordinary_spawn_chance = 0.08;
    NativeTerrainShapingRegistry registry(source, policy);
    const auto pages = world_effective_shaping_dependencies(source, primary);
    std::vector<NativeSiteSourceRegionKey> unresolved;
    const auto overrides = [](NativeTerrainPageKey page) {
        std::vector<NativeTownRegionOverride> result;
        for (std::int32_t z = page.z - 1; z <= page.z + 1; ++z)
            for (std::int32_t x = page.x - 1; x <= page.x + 1; ++x)
                result.push_back({x, z, false, {}});
        return result;
    };
    for (const auto page : pages) {
        const auto pin = registry.pin_page(page, overrides(page));
        for (const auto region : pin.unresolved_dependencies())
            if (std::find(unresolved.begin(), unresolved.end(), region) == unresolved.end())
                unresolved.push_back(region);
    }
    NativeTerrainShapingRegistryBatch batch;
    batch.expected_revision = registry.revision();
    for (const auto region : unresolved) {
        NativeSiteSourceResolution resolution;
        resolution.region = region;
        resolution.request_identity = registry.source_request_identity(region);
        resolution.worker_source_key.assign(64, 'a');
        resolution.kind = NativeSiteSourceResolutionKind::absent;
        resolution.reason_code = "ordinary_structure_overlap";
        batch.resolutions.push_back(std::move(resolution));
    }
    if (!batch.resolutions.empty()) static_cast<void>(registry.apply(batch));
    std::vector<NativeTerrainShapingPagePin> pins;
    for (const auto page : pages) pins.push_back(registry.pin_page(page, overrides(page)));
    return WorldSourcePin(source, deltas, primary, pins);
}

inline NativeSurfacePropSourceReceipt receipt(const WorldSourcePin &pin) {
    Sha256Digest profile_digest{};
    profile_digest.fill(4U);
    return NativeSurfacePropSourceReceipt::from_pin(pin, 7U, profile_digest);
}

} // namespace voxel::world_backend::surface_prop_test_fixture
