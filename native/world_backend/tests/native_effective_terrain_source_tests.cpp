#include "test_harness.hpp"

#include "../core/native_effective_terrain_source.hpp"
#include "../core/native_terrain_shaping_registry.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

bool near(const double left, const double right, const double tolerance = 1.0e-9) {
    return std::abs(left - right) <= tolerance;
}

std::uint32_t bits(const float value) {
    std::uint32_t result = 0;
    static_assert(sizeof(result) == sizeof(value));
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

WorldSourceDefinition flat_definition(
    const std::string &seed = "effective-flat", const double surface = 13.0,
    const double cell_size = 1.35) {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
    descriptor.revisions.terrain_generator_revision = 8;
    descriptor.revisions.lattice_query_revision = 6;
    descriptor.revisions.cell_center_query_revision = 7;
    descriptor.revisions.surface_column_query_revision = 8;
    descriptor.constants.minimum_surface_meters = surface;
    descriptor.constants.maximum_surface_meters = surface;
    descriptor.constants.cell_size_meters = cell_size;
    return WorldSourceDefinition(std::move(descriptor));
}

WorldSourceDefinition atlas_definition() {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("atlas-1492");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("atlas-1492");
    descriptor.revisions.terrain_generator_revision = 8;
    descriptor.revisions.lattice_query_revision = 6;
    descriptor.revisions.cell_center_query_revision = 7;
    descriptor.revisions.surface_column_query_revision = 8;
    return WorldSourceDefinition(std::move(descriptor));
}

NativeSiteSourcePolicy site_policy() {
    NativeSiteSourcePolicy policy;
    policy.engine_version_utf8 = "4.6.1.stable.official.14d19694e";
    policy.ordinary_region_cells = 140;
    policy.ordinary_spawn_chance = 0.08;
    return policy;
}

NativeTownRegionOverride town(
    const std::int32_t rx, const std::int32_t rz, const std::int32_t radius,
    const double level) {
    return {rx, rz, true, {rx, rz, rx * NativeTerrainShapingSnapshot::PAGE_CELLS,
        rz * NativeTerrainShapingSnapshot::PAGE_CELLS, radius, level}};
}

std::vector<NativeTownRegionOverride> overrides_for_page(
    const NativeTerrainPageKey page, const std::vector<NativeTownRegionOverride> &special) {
    std::vector<NativeTownRegionOverride> result;
    for (std::int32_t rz = page.z - 1; rz <= page.z + 1; ++rz) {
        for (std::int32_t rx = page.x - 1; rx <= page.x + 1; ++rx) {
            const auto found = std::find_if(special.begin(), special.end(), [&](const NativeTownRegionOverride &value) {
                return value.region_x == rx && value.region_z == rz;
            });
            result.push_back(found == special.end()
                ? NativeTownRegionOverride{rx, rz, false, {}}
                : *found);
        }
    }
    return result;
}

struct PreparedSite {
    NativeSiteSourceRegionKey region;
    NativeAdmittedSiteTerrainProfileHandle profile;
    NativeHorizontalRect source_reservation;
};

NativeSiteTerrainProfile site_profile(
    const NativeSiteSourceCandidate &candidate, const WorldSourceDefinition &definition,
    const double level = 1.0) {
    NativeSiteTerrainProfile profile;
    profile.world_seed_utf8 = definition.raw_terrain_seed().utf8;
    profile.site_id = candidate.site_id;
    profile.source_signature = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    profile.core_cells = {candidate.center_x - 1, candidate.center_z - 1, 3, 3};
    profile.envelope_cells = {candidate.center_x - 2, candidate.center_z - 2, 5, 5};
    profile.reservation_cells = profile.core_cells;
    profile.origin = {
        static_cast<float>(static_cast<double>(candidate.center_x) * profile.cell_size_meters),
        static_cast<float>(level),
        static_cast<float>(static_cast<double>(candidate.center_z) * profile.cell_size_meters),
    };
    profile.level_meters = level;
    profile.apron_cells = 1;
    profile.support_mask.assign(25, 0);
    profile.support_mask[12] = 1;
    profile.distance_cells.assign(25, 1.0F);
    profile.distance_cells[12] = 0.0F;
    profile.ground_root_points.assign(4, profile.origin);
    return profile;
}

PreparedSite prepared_site(
    const WorldSourceDefinition &definition, const NativeSiteSourceRegionKey region,
    const double level = 1.0) {
    const auto candidate = native_site_source_candidate_for_region(definition, region);
    VWB_EXPECT(candidate.has_value());
    NativeSiteTerrainProfile profile = site_profile(*candidate, definition, level);
    PreparedSite result;
    result.region = region;
    result.profile = admit_native_site_terrain_profile(definition, profile);
    result.source_reservation = {
        candidate->center_x - 3, candidate->center_z - 3, 7, 7,
    };
    return result;
}

std::int32_t floor_page(const std::int32_t cell) {
    return *floor_divide(cell, NativeTerrainShapingSnapshot::PAGE_CELLS);
}

WorldSourcePin ready_pin(
    const WorldSourceDefinition &definition,
    const NativeTerrainPageKey primary,
    const WorldDeltaPinnedSnapshot &deltas,
    const std::vector<NativeTownRegionOverride> &towns = {},
    const std::optional<PreparedSite> &prepared = std::nullopt) {
    NativeTerrainShapingRegistry registry(definition, site_policy());
    const auto page_keys = world_effective_shaping_dependencies(definition, primary);
    std::vector<NativeSiteSourceRegionKey> unresolved;
    for (const NativeTerrainPageKey page : page_keys) {
        const auto page_pin = registry.pin_page(page, overrides_for_page(page, towns));
        for (const NativeSiteSourceRegionKey region : page_pin.unresolved_dependencies()) {
            if (std::find(unresolved.begin(), unresolved.end(), region) == unresolved.end())
                unresolved.push_back(region);
        }
    }
    NativeTerrainShapingRegistryBatch batch;
    batch.expected_revision = registry.revision();
    for (const NativeSiteSourceRegionKey region : unresolved) {
        NativeSiteSourceResolution resolution;
        resolution.region = region;
        resolution.request_identity = registry.source_request_identity(region);
        resolution.worker_source_key.assign(64, 'a');
        if (prepared && prepared->region == region) {
            resolution.kind = NativeSiteSourceResolutionKind::prepared;
            resolution.profile = prepared->profile;
            resolution.manifest_source_signature = prepared->profile->source_signature();
            resolution.source_reservation_cells = prepared->source_reservation;
        } else {
            resolution.kind = NativeSiteSourceResolutionKind::absent;
            resolution.reason_code = "ordinary_structure_overlap";
        }
        batch.resolutions.push_back(std::move(resolution));
    }
    if (!batch.resolutions.empty()) static_cast<void>(registry.apply(batch));
    std::vector<NativeTerrainShapingPagePin> page_pins;
    for (const NativeTerrainPageKey page : page_keys)
        page_pins.push_back(registry.pin_page(page, overrides_for_page(page, towns)));
    return WorldSourcePin(definition, deltas, primary, page_pins);
}

WorldDeltaPinnedSnapshot empty_deltas() {
    const WorldDeltaStore store;
    return store.pin();
}

NativeCellState edited_state_with_metadata(
    const CellCoord cell, const double density, const TerrainMaterialId material,
    const NativeCellStateNamespace name_space, NativeValue metadata,
    const TerrainBiomeId biome = TerrainBiomeId::plains) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = material;
    input.biome = biome;
    input.solid = density >= 0.0;
    input.density = density;
    input.metadata = std::move(metadata);
    input.block_id = NativeBlockIdentity::create(material == TerrainMaterialId::stone ? "stone" : "grass");
    input.edit_reason = "effective-test";
    input.generated = false;
    input.edited = true;
    return make_native_cell_state(input, name_space);
}

NativeCellState edited_state(
    const CellCoord cell, const double density, const TerrainMaterialId material,
    const NativeCellStateNamespace name_space, const char *source,
    const TerrainBiomeId biome = TerrainBiomeId::plains) {
    return edited_state_with_metadata(cell, density, material, name_space, NativeValue::object({
        {"source", NativeValue::string(source)},
        {"terrainMeshAffects", NativeValue::boolean(name_space == NativeCellStateNamespace::durable_terrain)},
    }), biome);
}

WorldDeltaPinnedSnapshot typed_deltas(
    std::vector<NativeCellState> durable, std::vector<NativeCellState> overlays) {
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = "effective:policy";
    std::vector<NativeTypedWorldStateRecord> durable_records;
    for (NativeCellState &state : durable) durable_records.push_back({
        NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable,
        std::move(state),
    });
    for (NativeCellState &state : overlays) admission.transient_overlays.push_back({
        NativeCellStateNamespace::scene_overlay, NativeTypedWorldStatePersistence::transient,
        std::move(state),
    });
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(durable_records));
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

WorldDeltaPinnedSnapshot layered_deltas(const CellCoord cell) {
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = "effective:layers";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({{
            NativeCellStateNamespace::durable_terrain,
            NativeTypedWorldStatePersistence::durable,
            edited_state(cell, 0.7, TerrainMaterialId::stone,
                NativeCellStateNamespace::durable_terrain, "terrain_edit"),
        }});
    admission.transient_overlays = {{
            NativeCellStateNamespace::scene_overlay,
            NativeTypedWorldStatePersistence::transient,
            edited_state(cell, 1.35, TerrainMaterialId::grass,
                NativeCellStateNamespace::scene_overlay, "scene_block"),
        }};
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

WorldDeltaPinnedSnapshot durable_deltas(
    const CellCoord cell, const double density = 0.7,
    const TerrainMaterialId material = TerrainMaterialId::stone,
    const TerrainBiomeId biome = TerrainBiomeId::plains) {
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = "effective:durable";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({{
        NativeCellStateNamespace::durable_terrain,
        NativeTypedWorldStatePersistence::durable,
        edited_state(cell, density, material,
            NativeCellStateNamespace::durable_terrain, "terrain_edit", biome),
    }});
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

WorldDeltaPinnedSnapshot feature_only_deltas(const CellCoord cell) {
    WorldDeltaInitialSnapshot initial;
    initial.feature_delta_snapshot = NativeFeatureDeltaSnapshot::create({}, {{
        "v2/player-block/cell/0/0/0", cell, 0.0, 0.0,
        NativeBlockIdentity::create("torch"), NativeValue::object({}),
    }});
    const WorldDeltaStore store({}, std::move(initial));
    return store.pin();
}

} // namespace

VWB_TEST(native_effective_terrain_matches_flat_town_apron_biome_and_protection_goldens) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainSource source(ready_pin(definition, {0, 0}, empty_deltas(), {town(0, 0, 30, 10.0)}));
    const NativeNaturalTerrainSource natural(definition);
    const TerrainBiomeId regional = natural.sample_surface_biome({48, 0, WorldQueryIntent::gameplay});
    struct Golden { std::int32_t x; double surface; TerrainBiomeId biome; bool protected_surface; };
    const std::vector<Golden> goldens = {
        {0, 10.0, TerrainBiomeId::town, true},
        {30, 10.0, TerrainBiomeId::town, true},
        {31, 10.026748971193415, TerrainBiomeId::ocean, true},
        {38, 11.251028806584362, TerrainBiomeId::ocean, true},
        {39, 11.5, TerrainBiomeId::beach, true},
        {40, 11.748971193415638, TerrainBiomeId::beach, true},
        {48, 13.0, regional, true},
        {49, 13.0, regional, false},
    };
    for (const Golden &golden : goldens) {
        const auto column = source.sample_surface_column({golden.x, 0, WorldQueryIntent::terrain_collision});
        VWB_EXPECT(near(golden.surface, column.reference_surface_y));
        VWB_EXPECT(near(golden.surface, column.deformed_surface_y));
        VWB_EXPECT_EQ(golden.biome, source.sample_surface_biome({golden.x, 0, WorldQueryIntent::gameplay}));
        const auto &shape = source.pin().terrain_shaping_for_page({0, 0});
        const auto natural_sampler = [&natural](const std::int32_t x, const std::int32_t z) {
            return natural.sample_surface_column({x, z, WorldQueryIntent::gameplay}).reference_surface_y;
        };
        VWB_EXPECT_EQ(golden.protected_surface,
            shape.protects_minimum_overburden(golden.x, 0, natural_sampler));
    }
    const auto protected_subsurface = source.sample_cell_state({{0, 5, 0}, WorldQueryIntent::gameplay});
    VWB_EXPECT(protected_subsurface.solid);
    VWB_EXPECT(protected_subsurface.density > 0.0);
}

VWB_TEST(native_effective_terrain_uses_exact_shaped_ocean_beach_thresholds_and_town_core_override) {
    const auto below_ocean = flat_definition("threshold", 11.399999);
    const auto at_beach = flat_definition("threshold", 11.4);
    const auto below_regional = flat_definition("threshold", 12.799999);
    const auto at_regional = flat_definition("threshold", 12.8);
    NativeEffectiveTerrainSource ocean(ready_pin(below_ocean, {0, 0}, empty_deltas()));
    NativeEffectiveTerrainSource beach_low(ready_pin(at_beach, {0, 0}, empty_deltas()));
    NativeEffectiveTerrainSource beach_high(ready_pin(below_regional, {0, 0}, empty_deltas()));
    NativeEffectiveTerrainSource regional(ready_pin(at_regional, {0, 0}, empty_deltas()));
    VWB_EXPECT_EQ(TerrainBiomeId::ocean, ocean.sample_surface_biome({0, 0, WorldQueryIntent::gameplay}));
    VWB_EXPECT_EQ(TerrainBiomeId::beach, beach_low.sample_surface_biome({0, 0, WorldQueryIntent::gameplay}));
    VWB_EXPECT_EQ(TerrainBiomeId::beach, beach_high.sample_surface_biome({0, 0, WorldQueryIntent::gameplay}));
    VWB_EXPECT(regional.sample_surface_biome({0, 0, WorldQueryIntent::gameplay}) != TerrainBiomeId::ocean);
    VWB_EXPECT(regional.sample_surface_biome({0, 0, WorldQueryIntent::gameplay}) != TerrainBiomeId::beach);

    NativeEffectiveTerrainSource town_core(ready_pin(below_ocean, {0, 0}, empty_deltas(), {
        town(0, 0, 30, 1.0),
    }));
    VWB_EXPECT_EQ(TerrainBiomeId::town,
        town_core.sample_surface_biome({0, 0, WorldQueryIntent::gameplay}));

    // A site core is shaped terrain but not a town-biome override. Its exact
    // level therefore exercises the same strict ocean/beach thresholds.
    const auto site_definition = flat_definition("atlas-1492");
    const auto candidate = native_site_source_candidate_for_region(site_definition, {0, 0});
    VWB_EXPECT(candidate.has_value());
    const NativeTerrainPageKey site_page{floor_page(candidate->center_x), floor_page(candidate->center_z)};
    NativeEffectiveTerrainSource shaped_ocean(ready_pin(site_definition, site_page, empty_deltas(), {},
        prepared_site(site_definition, {0, 0}, 11.399999)));
    NativeEffectiveTerrainSource shaped_beach(ready_pin(site_definition, site_page, empty_deltas(), {},
        prepared_site(site_definition, {0, 0}, 11.4)));
    NativeEffectiveTerrainSource shaped_regional(ready_pin(site_definition, site_page, empty_deltas(), {},
        prepared_site(site_definition, {0, 0}, 12.8)));
    const WorldSurfaceColumnQuery site_query{candidate->center_x, candidate->center_z, WorldQueryIntent::gameplay};
    VWB_EXPECT_EQ(TerrainBiomeId::ocean, shaped_ocean.sample_surface_biome(site_query));
    VWB_EXPECT_EQ(TerrainBiomeId::beach, shaped_beach.sample_surface_biome(site_query));
    VWB_EXPECT(shaped_regional.sample_surface_biome(site_query) != TerrainBiomeId::ocean);
    VWB_EXPECT(shaped_regional.sample_surface_biome(site_query) != TerrainBiomeId::beach);
}

VWB_TEST(native_effective_terrain_town_selection_keeps_rz_rx_scan_and_strict_tie) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainSource source(ready_pin(definition, {0, 0}, empty_deltas(), {
        town(0, 0, 150, 10.0), town(1, 0, 150, 20.0),
    }));
    const auto tied = source.sample_surface_column({140, 0, WorldQueryIntent::gameplay});
    VWB_EXPECT(near(10.0, tied.reference_surface_y));
    VWB_EXPECT_EQ(TerrainBiomeId::town,
        source.sample_surface_biome({140, 0, WorldQueryIntent::gameplay}));
}

VWB_TEST(native_effective_terrain_applies_site_support_protection_and_town_before_site) {
    const auto definition = flat_definition("atlas-1492");
    const NativeSiteSourceRegionKey region{0, 0};
    const auto candidate = native_site_source_candidate_for_region(definition, region);
    VWB_EXPECT(candidate.has_value());
    const PreparedSite site = prepared_site(definition, region);
    const NativeTerrainPageKey page{floor_page(candidate->center_x), floor_page(candidate->center_z)};
    NativeEffectiveTerrainSource site_only(ready_pin(definition, page, empty_deltas(), {}, site));
    VWB_EXPECT(near(1.0, site_only.sample_surface_column({candidate->center_x, candidate->center_z,
        WorldQueryIntent::gameplay}).reference_surface_y));
    const auto sampler = [&site_only](const std::int32_t x, const std::int32_t z) {
        return site_only.pin().definition().constants().minimum_surface_meters + (x - x) + (z - z);
    };
    const auto &site_shape = site_only.pin().terrain_shaping_for_page(page);
    VWB_EXPECT(site_shape.protects_minimum_overburden(candidate->center_x, candidate->center_z, sampler));
    VWB_EXPECT(!site_shape.protects_minimum_overburden(candidate->center_x + 1, candidate->center_z, sampler));

    const std::int32_t town_rx = static_cast<std::int32_t>(std::llround(
        static_cast<double>(candidate->center_x) / NativeTerrainShapingSnapshot::PAGE_CELLS));
    const std::int32_t town_rz = static_cast<std::int32_t>(std::llround(
        static_cast<double>(candidate->center_z) / NativeTerrainShapingSnapshot::PAGE_CELLS));
    NativeEffectiveTerrainSource overlap(ready_pin(definition, page, empty_deltas(), {
        town(town_rx, town_rz, 120, 10.0),
    }, site));
    VWB_EXPECT(near(10.0, overlap.sample_surface_column({candidate->center_x, candidate->center_z,
        WorldQueryIntent::gameplay}).reference_surface_y));
    VWB_EXPECT_EQ(TerrainBiomeId::town, overlap.sample_surface_biome({candidate->center_x,
        candidate->center_z, WorldQueryIntent::gameplay}));
}

VWB_TEST(native_effective_terrain_overburden_transition_matches_unprotected_and_protected_goldens) {
    constexpr double cell = 1.35;
    constexpr double raw = -cell;
    VWB_EXPECT(near(cell, native_underground_density_from_raw(raw, cell, 3.0, 3.0)));
    VWB_EXPECT(near(0.0, native_underground_density_from_raw(raw, cell, 5.5, 3.0)));
    VWB_EXPECT(near(raw, native_underground_density_from_raw(raw, cell, 8.0, 3.0)));
    VWB_EXPECT(near(cell, native_underground_density_from_raw(raw, cell, 8.0, 8.0)));
    VWB_EXPECT(near(0.0, native_underground_density_from_raw(raw, cell, 10.5, 8.0)));
    VWB_EXPECT(near(raw, native_underground_density_from_raw(raw, cell, 13.0, 8.0)));
}

VWB_TEST(native_effective_terrain_preserves_material_bedrock_ore_fluid_order) {
    const auto definition = atlas_definition();
    const std::vector<CellCoord> cells = {
        {-30208, 8, -65536}, {-128, -62, -128}, {-43, -59, -128},
        {-56, -56, -128}, {-125, 3, -128}, {-127, 16, -128},
        {-128, 18, -128}, {0, -64, 0},
    };
    const NativeNaturalTerrainSource natural(definition);
    for (const CellCoord cell : cells) {
        const NativeTerrainPageKey page{floor_page(cell.x), floor_page(cell.z)};
        NativeEffectiveTerrainSource effective(ready_pin(definition, page, empty_deltas()));
        const auto expected = natural.sample_cell_state({cell, WorldQueryIntent::gameplay});
        const auto actual = effective.sample_cell_state({cell, WorldQueryIntent::gameplay});
        VWB_EXPECT_EQ(expected.material, actual.material);
        VWB_EXPECT_EQ(expected.biome, actual.biome);
        VWB_EXPECT_EQ(expected.fluid, actual.fluid);
        VWB_EXPECT_EQ(expected.solid, actual.solid);
        VWB_EXPECT(near(expected.density, actual.density));
    }

    const auto flooded_definition = flat_definition("effective-flooded", 4.0);
    NativeEffectiveTerrainSource flooded(ready_pin(flooded_definition, {0, 0}, empty_deltas()));
    const auto surface_water = flooded.sample_cell_state({{0, 5, 0}, WorldQueryIntent::gameplay});
    VWB_EXPECT_EQ(TerrainMaterialId::water, surface_water.material);
    VWB_EXPECT_EQ(TerrainFluidId::water, surface_water.fluid);
    VWB_EXPECT(!surface_water.solid);
}

VWB_TEST(native_effective_terrain_keeps_gameplay_lattice_world_and_projection_edit_semantics_distinct) {
    const auto definition = flat_definition();
    const CellCoord cell{0, 0, 0};
    NativeEffectiveTerrainSource source(ready_pin(definition, {0, 0}, layered_deltas(cell)));
    const auto gameplay = source.sample_cell_state({cell, WorldQueryIntent::gameplay});
    VWB_EXPECT_EQ(TerrainMaterialId::grass, gameplay.material);
    VWB_EXPECT(near(1.35, gameplay.density));
    const auto &metadata = gameplay.metadata.as_object();
    const auto source_field = std::find_if(metadata.begin(), metadata.end(), [](const auto &entry) {
        return entry.first == "source";
    });
    VWB_EXPECT(source_field != metadata.end());
    VWB_EXPECT_EQ(std::string("scene_block"), source_field->second.as_string());

    const auto lattice = source.sample_lattice_numeric({cell, WorldQueryIntent::terrain_mesh});
    VWB_EXPECT(!lattice.generated && lattice.edited);
    VWB_EXPECT(near(0.7, lattice.density));
    VWB_EXPECT_EQ(TerrainMaterialId::stone, lattice.material);

    const auto world = source.sample_world_numeric({0.0F, 0.0F, 0.0F});
    VWB_EXPECT(!world.generated && world.edited);
    VWB_EXPECT(near(-definition.constants().cell_size_meters, world.density));
    VWB_EXPECT_EQ(TerrainMaterialId::air, world.material);

    const auto projection = source.sample_surface_projection_numeric({cell, WorldQueryIntent::terrain_collision});
    VWB_EXPECT(projection.generated && !projection.edited);
    VWB_EXPECT(!near(0.7, projection.density));
    VWB_EXPECT(!near(1.35, projection.density));

    NativeEffectiveTerrainSource durable(ready_pin(definition, {0, 0}, durable_deltas(cell)));
    const auto durable_world = durable.sample_world_numeric({0.0F, 0.0F, 0.0F});
    const auto durable_projection = durable.sample_surface_projection_numeric({cell, WorldQueryIntent::terrain_collision});
    VWB_EXPECT(!durable_world.generated && durable_world.edited);
    VWB_EXPECT(near(0.7, durable_world.density));
    VWB_EXPECT(!durable_projection.generated && durable_projection.edited);
    VWB_EXPECT(near(0.7, durable_projection.density));

    NativeEffectiveTerrainSource generated(ready_pin(definition, {0, 0}, empty_deltas()));
    VWB_EXPECT(generated.sample_world_numeric({0.0F, 0.0F, 0.0F}).generated);
    VWB_EXPECT(generated.sample_surface_projection_numeric({cell, WorldQueryIntent::terrain_collision}).generated);
    VWB_EXPECT_EQ(TerrainMaterialId::bedrock,
        generated.sample_lattice_numeric({{0, -64, 0}, WorldQueryIntent::terrain_mesh}).material);

    NativeEffectiveTerrainSource edited_cave(ready_pin(definition, {0, 0},
        durable_deltas(cell, -1.35, TerrainMaterialId::air, TerrainBiomeId::underground_air)));
    const auto cave_lattice = edited_cave.sample_lattice_numeric({cell, WorldQueryIntent::terrain_mesh});
    VWB_EXPECT(cave_lattice.underground_air_void);
    VWB_EXPECT(!cave_lattice.generated && cave_lattice.edited);

    // A dug, non-solid edit is not necessarily generated underground air.
    // Exercise that distinction through both numeric entry points so the
    // translated short-circuit expression remains observable.
    NativeEffectiveTerrainSource edited_open_air(ready_pin(definition, {0, 0},
        durable_deltas(cell, -1.35, TerrainMaterialId::air, TerrainBiomeId::plains)));
    const auto open_lattice = edited_open_air.sample_lattice_numeric({cell, WorldQueryIntent::terrain_mesh});
    const auto open_world = edited_open_air.sample_world_numeric({0.0F, 0.0F, 0.0F});
    VWB_EXPECT(!open_lattice.underground_air_void);
    VWB_EXPECT(!open_world.underground_air_void);
    VWB_EXPECT(!open_world.generated && open_world.edited);
}

VWB_TEST(native_effective_world_numeric_uses_remapped_cell_center_state_and_arbitrary_surface) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainSource source(ready_pin(definition, {0, 0}, empty_deltas()));
    const float arbitrary_y = 12.2F;
    const auto numeric = source.sample_world_numeric({0.1F, arbitrary_y, 0.1F});
    const auto center = source.sample_cell_state({{0, 9, 0}, WorldQueryIntent::gameplay});
    VWB_EXPECT_EQ((CellCoord{0, 9, 0}), numeric.source_cell);
    VWB_EXPECT(near(center.density, numeric.density));
    VWB_EXPECT(!near(13.0 - static_cast<double>(arbitrary_y), numeric.density));
    VWB_EXPECT(near(13.0, numeric.surface_y));
}

VWB_TEST(native_effective_metadata_policies_are_state_owned_and_keep_exact_precedence) {
    const auto definition = flat_definition();
    const double cell_size = definition.constants().cell_size_meters;
    const auto metadata = [](NativeValue::Object value) { return NativeValue::object(std::move(value)); };
    std::vector<NativeCellState> durable = {
        edited_state_with_metadata({0, 0, 0}, 0.7, TerrainMaterialId::stone,
            NativeCellStateNamespace::durable_terrain, metadata({{"source", NativeValue::string("terrain_edit")}})),
        edited_state_with_metadata({1, 0, 0}, 1.1, TerrainMaterialId::stone,
            NativeCellStateNamespace::durable_terrain, metadata({
                {"source", NativeValue::string("structure_wall")},
                {"terrainMeshAffects", NativeValue::boolean(true)},
            })),
        edited_state_with_metadata({2, 0, 0}, 1.2, TerrainMaterialId::stone,
            NativeCellStateNamespace::durable_terrain, metadata({
                {"source", NativeValue::string("terrain_edit")},
                {"terrainMeshAffects", NativeValue::boolean(false)},
            })),
        edited_state_with_metadata({3, 0, 0}, 1.3, TerrainMaterialId::stone,
            NativeCellStateNamespace::durable_terrain, metadata({
                {"renderedBySceneBlock", NativeValue::boolean(true)},
                {"source", NativeValue::string("terrain_edit")},
            })),
        edited_state_with_metadata({4, 0, 0}, 1.4, TerrainMaterialId::stone,
            NativeCellStateNamespace::durable_terrain, metadata({
                {"renderedBySceneBlock", NativeValue::boolean(false)},
                {"source", NativeValue::string("scene_block")},
            })),
        edited_state_with_metadata({5, 0, 0}, 1.5, TerrainMaterialId::stone,
            NativeCellStateNamespace::durable_terrain, metadata({
                {"renderedBySceneBlock", NativeValue::boolean(false)},
                {"source", NativeValue::string("terrain_edit")},
            })),
        edited_state_with_metadata({6, 0, 0}, 1.6, TerrainMaterialId::stone,
            NativeCellStateNamespace::durable_terrain, metadata({
                {"source", NativeValue::number(7.0)},
            })),
    };
    std::vector<NativeCellState> overlays = {
        edited_state_with_metadata({0, 0, 0}, 2.0, TerrainMaterialId::grass,
            NativeCellStateNamespace::scene_overlay, metadata({
                {"renderedBySceneBlock", NativeValue::boolean(true)},
                {"source", NativeValue::string("scene_block")},
                {"terrainMeshAffects", NativeValue::boolean(true)},
            })),
    };

    NativeEffectiveTerrainSource source(ready_pin(definition, {0, 0},
        typed_deltas(std::move(durable), std::move(overlays))));
    const auto world_at = [&](const std::int32_t x) {
        return source.sample_world_numeric({
            static_cast<float>((static_cast<double>(x) + 0.5) * cell_size),
            static_cast<float>(0.5 * cell_size),
            static_cast<float>(0.5 * cell_size),
        });
    };
    const auto projection_at = [&](const std::int32_t x) {
        return source.sample_surface_projection_numeric({{x, 0, 0}, WorldQueryIntent::terrain_collision});
    };

    // terrainMeshAffects is first for mesh policy, so an overlay can opt in
    // even when its later presentation metadata identifies a scene block.
    VWB_EXPECT(near(2.0, world_at(0).density));
    VWB_EXPECT(projection_at(0).generated);
    // Projection checks structure/scene presentation before the mesh flag.
    VWB_EXPECT(near(1.1, world_at(1).density));
    VWB_EXPECT(projection_at(1).generated);
    // A durable record can independently opt out of both numeric consumers.
    VWB_EXPECT(near(-cell_size, world_at(2).density));
    VWB_EXPECT(projection_at(2).generated);
    VWB_EXPECT(near(-cell_size, world_at(3).density));
    VWB_EXPECT(projection_at(3).generated);
    VWB_EXPECT(near(-cell_size, world_at(4).density));
    VWB_EXPECT(projection_at(4).generated);
    VWB_EXPECT(near(1.5, world_at(5).density));
    VWB_EXPECT(!projection_at(5).generated);
    VWB_EXPECT(near(1.6, world_at(6).density));
    VWB_EXPECT(!projection_at(6).generated);

    // Captured directly from Godot 4.6.1 Variant bool conversion. Unlike
    // JavaScript/Python-style truthiness, only bool and numeric metadata are
    // accepted by bool(Variant); strings and containers are invalid calls.
    struct TruthCase { NativeValue value; bool expected; };
    std::vector<TruthCase> truth = {
        {NativeValue::boolean(false), false},
        {NativeValue::boolean(true), true},
        {NativeValue::number(0.0), false},
        {NativeValue::number(2.0), true},
    };
    std::vector<NativeCellState> truth_states;
    for (std::size_t index = 0; index < truth.size(); ++index) {
        truth_states.push_back(edited_state_with_metadata(
            {10 + static_cast<std::int32_t>(index), 0, 0}, 2.5, TerrainMaterialId::stone,
            NativeCellStateNamespace::durable_terrain,
            metadata({{"terrainMeshAffects", truth[index].value}})));
    }
    NativeEffectiveTerrainSource truth_source(ready_pin(definition, {0, 0},
        typed_deltas(std::move(truth_states), {})));
    for (std::size_t index = 0; index < truth.size(); ++index) {
        const std::int32_t x = 10 + static_cast<std::int32_t>(index);
        const auto actual = truth_source.sample_world_numeric({
            static_cast<float>((static_cast<double>(x) + 0.5) * cell_size),
            static_cast<float>(0.5 * cell_size),
            static_cast<float>(0.5 * cell_size),
        });
        VWB_EXPECT(near(truth[index].expected ? 2.5 : -cell_size, actual.density));
    }

    NativeEffectiveTerrainSource invalid_boolean(ready_pin(definition, {0, 0},
        typed_deltas({edited_state_with_metadata(
            {20, 0, 0}, 2.5, TerrainMaterialId::stone,
            NativeCellStateNamespace::durable_terrain,
            metadata({{"terrainMeshAffects", NativeValue::string("true")}}))}, {})));
    VWB_EXPECT_THROW(std::invalid_argument, invalid_boolean.sample_world_numeric({
        static_cast<float>(20.5 * cell_size),
        static_cast<float>(0.5 * cell_size),
        static_cast<float>(0.5 * cell_size),
    }));
}

VWB_TEST(native_effective_terrain_never_coerces_feature_blocks_into_terrain) {
    const auto definition = flat_definition();
    const CellCoord cell{0, 20, 0};
    NativeEffectiveTerrainSource empty(ready_pin(definition, {0, 0}, empty_deltas()));
    NativeEffectiveTerrainSource feature(ready_pin(definition, {0, 0}, feature_only_deltas(cell)));
    const auto expected = empty.sample_cell_state({cell, WorldQueryIntent::gameplay});
    const auto actual = feature.sample_cell_state({cell, WorldQueryIntent::gameplay});
    VWB_EXPECT_EQ(expected, actual);
    VWB_EXPECT(feature.pin().deltas().feature_delta_snapshot().player_created_instances().size() == 1U);
}

VWB_TEST(native_effective_terrain_uses_remapped_source_pages_and_fails_closed_outside_pin) {
    const auto definition = flat_definition();
    const CellCoord ordinary{-20, 13, -2};
    NativeEffectiveTerrainSource source(ready_pin(definition, {-1, -1}, empty_deltas()));
    const auto remapped = source.sample_lattice_numeric({ordinary, WorldQueryIntent::terrain_mesh});
    VWB_EXPECT_EQ(ordinary, remapped.requested_cell);
    VWB_EXPECT(!(ordinary == remapped.source_cell));
    VWB_EXPECT_EQ(-20, remapped.source_cell.x);
    VWB_EXPECT_EQ(-3, remapped.source_cell.z);

    const auto two_boundary = resolve_world_query(definition,
        WorldLatticeQuery{{9, 0, 0}, WorldQueryIntent::terrain_collision});
    const auto one_boundary = resolve_native_surface_projection_query(definition,
        {{9, 0, 0}, WorldQueryIntent::terrain_collision});
    VWB_EXPECT_EQ(0x41426667U, bits(two_boundary.lattice_position.x));
    VWB_EXPECT_EQ(0x41426666U, bits(one_boundary.position.x));
    NativeEffectiveTerrainSource projection_source(ready_pin(definition, {0, 0},
        durable_deltas({9, 0, 0}), {town(0, 0, 8, 10.0)}));
    const auto projected = projection_source.sample_surface_projection_numeric({{9, 0, 0}, WorldQueryIntent::terrain_collision});
    VWB_EXPECT_EQ(8, projected.source_cell.x);
    VWB_EXPECT(near(10.026748971193415, projected.surface_y));

    // 1960 is exactly the first cell of page 7. Godot's float32 lattice
    // multiplication remaps it to source cell 1959 on page 6; the canonical
    // WorldSourcePin dependency set must make that cross-page query complete.
    NativeEffectiveTerrainSource boundary(ready_pin(definition, {7, 0}, empty_deltas()));
    const auto boundary_sample = boundary.sample_lattice_numeric({{1960, 0, 0}, WorldQueryIntent::terrain_mesh});
    VWB_EXPECT_EQ(1960, boundary_sample.requested_cell.x);
    VWB_EXPECT_EQ(1959, boundary_sample.source_cell.x);
    VWB_EXPECT_EQ(7, floor_page(boundary_sample.requested_cell.x));
    VWB_EXPECT_EQ(6, floor_page(boundary_sample.source_cell.x));

    // A WGS grid position can remap from the primary page into a dependency
    // page. World-position sampling must admit that source, and its typed
    // projection must participate in the pin's physical identity.
    constexpr std::int32_t wgs_grid_x = 24855320;
    constexpr std::int32_t wgs_source_x = 24855318;
    const NativeTerrainPageKey wgs_primary{floor_page(wgs_grid_x), 0};
    const WorldFloat32Position wgs_position{
        static_cast<float>(static_cast<double>(wgs_grid_x)
            * definition.constants().cell_size_meters),
        0.0F,
        0.0F,
    };
    NativeEffectiveTerrainSource wgs_empty(
        ready_pin(definition, wgs_primary, empty_deltas()));
    const auto wgs_generated = wgs_empty.sample_world_numeric(wgs_position);
    VWB_EXPECT_EQ(wgs_source_x, wgs_generated.source_cell.x);
    VWB_EXPECT_EQ(wgs_primary.x, floor_page(wgs_grid_x));
    VWB_EXPECT_EQ(wgs_primary.x - 1, floor_page(wgs_generated.source_cell.x));
    NativeEffectiveTerrainSource wgs_edited(ready_pin(definition, wgs_primary,
        durable_deltas({wgs_source_x, 0, 0}, 2.5, TerrainMaterialId::stone)));
    const auto wgs_typed = wgs_edited.sample_world_numeric(wgs_position);
    VWB_EXPECT(wgs_typed.edited && !wgs_typed.generated);
    VWB_EXPECT(near(2.5, wgs_typed.density));
    VWB_EXPECT_EQ(TerrainMaterialId::stone, wgs_typed.material);
    VWB_EXPECT(!(wgs_empty.pin().physical_content_identity()
        == wgs_edited.pin().physical_content_identity()));
    VWB_EXPECT_THROW(std::out_of_range,
        wgs_edited.sample_cell_state(
            {{wgs_source_x, 0, 0}, WorldQueryIntent::gameplay}));

    const std::int32_t extreme_x = 16777219;
    const NativeTerrainPageKey extreme_page{floor_page(extreme_x), 0};
    NativeEffectiveTerrainSource extreme(ready_pin(definition, extreme_page, empty_deltas()));
    const auto extreme_sample = extreme.sample_lattice_numeric({{extreme_x, 0, 0}, WorldQueryIntent::terrain_mesh});
    VWB_EXPECT_EQ(extreme_x, extreme_sample.requested_cell.x);
    VWB_EXPECT(extreme_sample.source_cell.x != extreme_x);
    VWB_EXPECT_THROW(std::out_of_range,
        source.sample_world_numeric({1000000.0F, 0.0F, 1000000.0F}));

    const CellCoord outside_cell{1000000, 4, 1000000};
    const auto outside_durable_deltas = typed_deltas({edited_state(
        outside_cell, 0.7, TerrainMaterialId::stone,
        NativeCellStateNamespace::durable_terrain, "terrain_edit")}, {});
    const auto outside_overlay_deltas = typed_deltas({}, {edited_state(
        outside_cell, 1.35, TerrainMaterialId::grass,
        NativeCellStateNamespace::scene_overlay, "scene_block")});
    NativeEffectiveTerrainSource outside_durable(
        ready_pin(definition, {0, 0}, outside_durable_deltas));
    NativeEffectiveTerrainSource outside_overlay(
        ready_pin(definition, {0, 0}, outside_overlay_deltas));
    NativeEffectiveTerrainSource empty(ready_pin(definition, {0, 0}, empty_deltas()));
    VWB_EXPECT_EQ(empty.pin().physical_content_identity(),
        outside_durable.pin().physical_content_identity());
    VWB_EXPECT_EQ(empty.pin().physical_content_identity(),
        outside_overlay.pin().physical_content_identity());
    VWB_EXPECT_THROW(std::out_of_range,
        outside_durable.sample_cell_state({outside_cell, WorldQueryIntent::gameplay}));
    VWB_EXPECT_THROW(std::out_of_range,
        outside_overlay.sample_cell_state({outside_cell, WorldQueryIntent::gameplay}));
    VWB_EXPECT_THROW(std::out_of_range,
        outside_durable.sample_lattice_numeric({outside_cell, WorldQueryIntent::terrain_mesh}));
    VWB_EXPECT_THROW(std::out_of_range,
        outside_overlay.sample_surface_projection_numeric(
            {outside_cell, WorldQueryIntent::terrain_collision}));
    VWB_EXPECT_THROW(std::out_of_range,
        outside_durable.sample_surface_column(
            {outside_cell.x, outside_cell.z, WorldQueryIntent::gameplay}));
    VWB_EXPECT_THROW(std::out_of_range,
        outside_overlay.sample_surface_biome(
            {outside_cell.x, outside_cell.z, WorldQueryIntent::gameplay}));
    VWB_EXPECT_THROW(std::invalid_argument,
        outside_durable.sample_cell_state(
            {outside_cell, static_cast<WorldQueryIntent>(255)}));
    VWB_EXPECT_THROW(std::invalid_argument,
        source.sample_world_numeric({std::numeric_limits<float>::quiet_NaN(), 0.0F, 0.0F}));
    VWB_EXPECT_THROW(std::invalid_argument,
        source.sample_world_numeric({std::numeric_limits<float>::max(), 0.0F, 0.0F}));
    VWB_EXPECT_THROW(std::invalid_argument,
        source.sample_world_numeric({std::numeric_limits<float>::lowest(), 0.0F, 0.0F}));

    const double maximum_admitting_cell_size = 2147483648.0 / 2147483647.5;
    const auto edge_definition = flat_definition("effective-int32-edge", 13.0, maximum_admitting_cell_size);
    NativeEffectiveTerrainSource edge(ready_pin(edge_definition, {0, 0}, empty_deltas()));
    // The quotient is INT32_MAX+0.5, whose floored cell is still INT32_MAX.
    // Page lookup then fails closed because that edge cell lies beyond this
    // pin, proving position admission did not reject the valid floored cell.
    VWB_EXPECT_THROW(std::out_of_range,
        edge.sample_world_numeric({2147483648.0F, 0.0F, 0.0F}));
}
