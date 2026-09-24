#include "test_harness.hpp"
#include "native_value_test_access.hpp"

#include "../core/native_generated_terrain_patch.hpp"

#include <cmath>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

WorldPhysicalContentIdentity world_identity(const std::uint8_t salt = 1U) {
    WorldPhysicalContentIdentity result;
    for (std::size_t index = 0U; index < result.digest.size(); ++index) {
        result.digest[index] = static_cast<std::uint8_t>(salt + index);
    }
    return result;
}

NativeGeneratedTerrainCellTemplate solid_state(
    const TerrainMaterialId material = TerrainMaterialId::dirt,
    const TerrainBiomeId biome = TerrainBiomeId::town) {
    NativeGeneratedTerrainCellTemplate result;
    result.material = material;
    result.biome = biome;
    result.solid = true;
    result.density = 1.35;
    result.metadata = NativeValue::object({{"source", NativeValue::string("structure")}});
    return result;
}

NativeGeneratedTerrainCellTemplate air_state() {
    NativeGeneratedTerrainCellTemplate result;
    result.material = TerrainMaterialId::air;
    result.biome = TerrainBiomeId::town;
    result.solid = false;
    result.density = -1.35;
    result.metadata = NativeValue::object({{"source", NativeValue::string("structure_reserved_air")}});
    return result;
}

NativeGeneratedTerrainPatchOperation operation(
    std::string id,
    const std::uint32_t ordinal,
    const NativeInclusiveCellBox bounds = {{0, 0, 0}, {0, 0, 0}},
    NativeGeneratedTerrainCellTemplate state = solid_state()) {
    NativeGeneratedTerrainPatchOperation result;
    result.owner_feature_id = std::move(id);
    result.recipe_revision = 7U;
    result.deterministic_order = 10U;
    result.operation_ordinal = ordinal;
    if (!state.solid) result.role = NativeGeneratedTerrainPatchRole::interior_clearance;
    result.bounds = bounds;
    result.state = std::move(state);
    return result;
}

NativeGeneratedTerrainPatchManifestDescriptor descriptor(
    std::vector<NativeGeneratedTerrainPatchOperation> operations,
    const std::uint64_t feature_revision = 11U) {
    NativeGeneratedTerrainPatchManifestDescriptor result;
    result.world_physical_identity = world_identity();
    result.region_id = "region:test";
    result.complete_region_bounds = {
        {std::numeric_limits<std::int32_t>::min(), std::numeric_limits<std::int32_t>::min(),
            std::numeric_limits<std::int32_t>::min()},
        {std::numeric_limits<std::int32_t>::max(), std::numeric_limits<std::int32_t>::max(),
            std::numeric_limits<std::int32_t>::max()}};
    result.producer_revision = 3U;
    result.feature_source_revision = feature_revision;
    result.operations = std::move(operations);
    return result;
}

NativeGeneratedTerrainPatchManifest admit(std::vector<NativeGeneratedTerrainPatchOperation> operations) {
    return NativeGeneratedTerrainPatchManifest::admit(descriptor(std::move(operations)));
}

NativeGeneratedTerrainPageDomain page(
    const NativeInclusiveCellBox bounds = {{0, 0, 0}, {15, 15, 15}},
    const std::uint8_t halo = 0U) {
    return {"page:test", {0, 0, 0}, bounds, {halo, halo, halo}};
}

template <typename Callable>
void expect_failure(const NativeGeneratedTerrainPatchFailure expected, Callable &&callable) {
    try {
        callable();
    } catch (const NativeGeneratedTerrainPatchError &error) {
        VWB_EXPECT_EQ(expected, error.failure());
        return;
    }
    VWB_EXPECT(false);
}

NativeValue numeric_metadata() {
    NativeValue::Array values;
    values.reserve(NativeValueLimits::MAX_CONTAINER_ENTRIES);
    for (std::size_t index = 0; index < NativeValueLimits::MAX_CONTAINER_ENTRIES; ++index) {
        values.push_back(NativeValue::number(static_cast<double>(index)));
    }
    return NativeValue::object({{"values", NativeValue::array(std::move(values))}});
}

NativeValue null_array(const std::size_t count = NativeValueLimits::MAX_CONTAINER_ENTRIES) {
    NativeValue::Array values;
    values.reserve(count);
    for (std::size_t index = 0U; index < count; ++index) values.push_back(NativeValue::null());
    return NativeValue::array(std::move(values));
}

NativeValue null_array_metadata(const std::size_t extra_count = 0U, const bool include_extra = false) {
    NativeValue::Object entries;
    entries.reserve(include_extra ? 2U : 1U);
    if (include_extra) entries.emplace_back("more", null_array(extra_count));
    entries.emplace_back("values", null_array());
    return NativeValue::object(std::move(entries));
}

NativeValue null_object_metadata() {
    NativeValue::Object values;
    values.reserve(NativeValueLimits::MAX_CONTAINER_ENTRIES);
    for (std::size_t index = 0U; index < NativeValueLimits::MAX_CONTAINER_ENTRIES; ++index) {
        const std::string digits = std::to_string(10000U + index).substr(1U);
        values.emplace_back(digits, NativeValue::null());
    }
    return NativeValue::object({{"values", NativeValue::object(std::move(values))}});
}

std::vector<NativeGeneratedTerrainPatchOperation> null_array_operations(
    const std::size_t count, const std::size_t full_extra_count = 0U,
    const std::size_t partial_extra_count = 0U) {
    std::vector<NativeGeneratedTerrainPatchOperation> result;
    result.reserve(count);
    for (std::size_t index = 0U; index < count; ++index) {
        NativeGeneratedTerrainCellTemplate state = solid_state();
        const bool full_extra = index < full_extra_count;
        const bool partial_extra = index == full_extra_count && partial_extra_count != 0U;
        state.metadata = null_array_metadata(
            full_extra ? NativeValueLimits::MAX_CONTAINER_ENTRIES : partial_extra_count,
            full_extra || partial_extra);
        result.push_back(operation("null-retained:" + std::to_string(index),
            static_cast<std::uint32_t>(index), {{0, 0, 0}, {0, 0, 0}}, std::move(state)));
    }
    return result;
}

} // namespace

VWB_TEST(generated_patch_models_current_three_box_structure_geometry_without_save_or_overlay_authority) {
    NativeGeneratedTerrainPatchOperation foundation = operation("house:4,8", 0U,
        {{-1, -3, -1}, {10, -1, 8}}, solid_state());
    foundation.role = NativeGeneratedTerrainPatchRole::foundation_fill;
    NativeGeneratedTerrainPatchOperation cap = operation("house:4,8", 1U,
        {{-1, 0, -1}, {10, 0, 8}}, solid_state(TerrainMaterialId::grass));
    cap.role = NativeGeneratedTerrainPatchRole::floor_cap;
    NativeGeneratedTerrainPatchOperation interior = operation("house:4,8", 2U,
        {{1, 1, 1}, {8, 4, 6}}, air_state());
    interior.role = NativeGeneratedTerrainPatchRole::interior_clearance;
    interior.lifecycle = NativeGeneratedTerrainPatchLifecycle::follows_feature_tombstone;

    NativeGeneratedTerrainPatchManifestDescriptor input = descriptor({interior, foundation, cap});
    input.region_id = "town:0,0";
    input.complete_region_bounds = {{-16, -8, -16}, {31, 31, 31}};
    const NativeGeneratedTerrainPatchManifest manifest = NativeGeneratedTerrainPatchManifest::admit(std::move(input));

    VWB_EXPECT_EQ(1U, manifest.schema_revision());
    VWB_EXPECT_EQ(std::string("town:0,0"), manifest.region_id());
    VWB_EXPECT_EQ(3U, manifest.producer_revision());
    VWB_EXPECT_EQ(11ULL, manifest.feature_source_revision());
    VWB_EXPECT_EQ(3U, manifest.operations().size());
    VWB_EXPECT_EQ(NativeGeneratedTerrainPatchRole::foundation_fill, manifest.operations()[0].role);
    VWB_EXPECT_EQ(NativeTerrainSourceLayer::generated_feature_terrain, manifest.operations()[0].source_layer);
    VWB_EXPECT(!manifest.canonical_binary().empty());
    VWB_EXPECT_EQ(64U, manifest.content_digest_hex().size());
    VWB_EXPECT_EQ(world_identity().digest, manifest.world_physical_identity().digest);
    VWB_EXPECT((manifest.complete_region_bounds() == NativeInclusiveCellBox{{-16, -8, -16}, {31, 31, 31}}));
    VWB_EXPECT_EQ(8U, manifest.affected_sections().size());

    const NativeGeneratedTerrainPatchPageSnapshot snapshot =
        NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page({{-16, -8, -16}, {15, 15, 15}}));
    VWB_EXPECT_EQ(std::string("page:test"), snapshot.domain().page_id);
    VWB_EXPECT((snapshot.projected_bounds() == NativeInclusiveCellBox{{-16, -8, -16}, {15, 15, 15}}));
    VWB_EXPECT_EQ(3U, snapshot.operations().size());
    VWB_EXPECT_EQ(8U, snapshot.affected_sections().size());
    VWB_EXPECT(!snapshot.canonical_binary().empty());
    VWB_EXPECT_EQ(64U, snapshot.projection_digest_hex().size());
    const auto floor = snapshot.resolve({0, 0, 0});
    VWB_EXPECT(floor.has_value());
    VWB_EXPECT_EQ(TerrainMaterialId::grass, floor->state.material);
    const auto room = snapshot.resolve({1, 1, 1});
    VWB_EXPECT(room.has_value());
    VWB_EXPECT(!room->state.solid);
    VWB_EXPECT_EQ(std::string("house:4,8"), room->owner_feature_id);
    VWB_EXPECT_EQ(7U, room->recipe_revision);
    VWB_EXPECT_EQ(10U, room->deterministic_order);
    VWB_EXPECT_EQ(2U, room->operation_ordinal);
    VWB_EXPECT_EQ(NativeGeneratedTerrainPatchRole::interior_clearance, room->role);
    VWB_EXPECT_EQ(NativeGeneratedTerrainPatchLifecycle::follows_feature_tombstone, room->lifecycle);
}

VWB_TEST(generated_patch_frozen_structure_system_three_box_authority_is_byte_exact) {
    NativeGeneratedTerrainCellTemplate foundation_state_value;
    foundation_state_value.material = TerrainMaterialId::stone;
    foundation_state_value.biome = TerrainBiomeId::town;
    foundation_state_value.solid = true;
    foundation_state_value.density = 2.2275;
    foundation_state_value.fluid = TerrainFluidId::none;
    foundation_state_value.light = {0U, 0U};
    foundation_state_value.metadata = NativeValue::object({
        {"source", NativeValue::string("structure_foundation")},
        {"structureSource", NativeValue::string("town_home")},
    });
    NativeGeneratedTerrainCellTemplate cap_state_value;
    cap_state_value.material = TerrainMaterialId::stone;
    cap_state_value.biome = TerrainBiomeId::town;
    cap_state_value.solid = true;
    cap_state_value.density = 0.108;
    cap_state_value.fluid = TerrainFluidId::none;
    cap_state_value.light = {0U, 0U};
    cap_state_value.metadata = NativeValue::object({
        {"source", NativeValue::string("structure_floor_cap")},
        {"structureSource", NativeValue::string("town_home")},
    });
    NativeGeneratedTerrainCellTemplate air_state_value;
    air_state_value.material = TerrainMaterialId::air;
    air_state_value.biome = TerrainBiomeId::town;
    air_state_value.solid = false;
    air_state_value.density = -1.35;
    air_state_value.fluid = TerrainFluidId::none;
    air_state_value.light = {15U, 0U};
    air_state_value.metadata = NativeValue::object({
        {"source", NativeValue::string("structure_reserved_air")},
        {"structureSource", NativeValue::string("town_home")},
    });

    NativeGeneratedTerrainPatchOperation foundation_value;
    foundation_value.owner_feature_id = "structure:town_home:4,8";
    foundation_value.recipe_revision = 1U;
    foundation_value.deterministic_order = 100U;
    foundation_value.operation_ordinal = 0U;
    foundation_value.role = NativeGeneratedTerrainPatchRole::foundation_fill;
    foundation_value.lifecycle = NativeGeneratedTerrainPatchLifecycle::permanent_site_shaping;
    foundation_value.bounds = {{3, 9, 7}, {14, 11, 16}};
    foundation_value.state = foundation_state_value;
    NativeGeneratedTerrainPatchOperation cap_value = foundation_value;
    cap_value.operation_ordinal = 1U;
    cap_value.role = NativeGeneratedTerrainPatchRole::floor_cap;
    cap_value.bounds = {{3, 12, 7}, {14, 12, 16}};
    cap_value.state = cap_state_value;
    NativeGeneratedTerrainPatchOperation air_value = foundation_value;
    air_value.operation_ordinal = 2U;
    air_value.role = NativeGeneratedTerrainPatchRole::interior_clearance;
    air_value.lifecycle = NativeGeneratedTerrainPatchLifecycle::follows_feature_tombstone;
    air_value.bounds = {{5, 13, 9}, {12, 16, 14}};
    air_value.state = air_state_value;

    NativeGeneratedTerrainPatchManifestDescriptor frozen_input;
    frozen_input.world_physical_identity = world_identity(41U);
    frozen_input.region_id = "structure-system-fixture:town:0,0";
    frozen_input.complete_region_bounds = {{0, 0, 0}, {31, 31, 31}};
    frozen_input.producer_revision = 1U;
    frozen_input.feature_source_revision = 27U;
    frozen_input.operations = {air_value, foundation_value, cap_value};
    const auto manifest = NativeGeneratedTerrainPatchManifest::admit(frozen_input);
    VWB_EXPECT_EQ(3U, manifest.operations().size());
    VWB_EXPECT_EQ(601U, manifest.canonical_binary().size());
    VWB_EXPECT_EQ(std::string("ef5a3d80a0d55e4b3ed833c22f53c2cd566f60bdba591028080bd944c0989501"),
        manifest.content_digest_hex());

    NativeGeneratedTerrainPageDomain frozen_page{
        "structure-system-fixture-page", {0, 0, 0}, {{0, 0, 0}, {31, 31, 31}}, {0U, 0U, 0U}};
    const auto snapshot = NativeGeneratedTerrainPatchPageSnapshot::project(manifest, frozen_page);
    const auto foundation_cell = snapshot.resolve({3, 9, 7});
    const auto cap_cell = snapshot.resolve({14, 12, 16});
    const auto interior_cell = snapshot.resolve({5, 13, 9});
    VWB_EXPECT(foundation_cell.has_value());
    VWB_EXPECT(cap_cell.has_value());
    VWB_EXPECT(interior_cell.has_value());
    VWB_EXPECT_EQ(NativeGeneratedTerrainPatchRole::foundation_fill, foundation_cell->role);
    VWB_EXPECT_EQ(NativeGeneratedTerrainPatchRole::floor_cap, cap_cell->role);
    VWB_EXPECT_EQ(NativeGeneratedTerrainPatchRole::interior_clearance, interior_cell->role);
    VWB_EXPECT_EQ(2.2275, foundation_cell->state.density);
    VWB_EXPECT_EQ(0.108, cap_cell->state.density);
    VWB_EXPECT_EQ(-1.35, interior_cell->state.density);
    VWB_EXPECT_EQ(15U, interior_cell->state.light.sky);
    VWB_EXPECT_EQ(TerrainMaterialId::stone, foundation_cell->state.material);
    VWB_EXPECT_EQ(TerrainBiomeId::town, cap_cell->state.biome);
    VWB_EXPECT_EQ(TerrainFluidId::none, interior_cell->state.fluid);
    VWB_EXPECT_EQ(std::string("structure_reserved_air"),
        interior_cell->state.metadata.as_object()[0].second.as_string());
    VWB_EXPECT_EQ(std::string("town_home"),
        interior_cell->state.metadata.as_object()[1].second.as_string());
}

VWB_TEST(generated_patch_negative_coordinates_and_inclusive_edges_are_exact) {
    const NativeGeneratedTerrainPatchManifest manifest = admit({operation("negative", 0U,
        {{-17, -16, -1}, {-16, -1, 0}})});
    const NativeGeneratedTerrainPatchPageSnapshot snapshot =
        NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page({{-32, -32, -16}, {-1, 15, 15}}));
    VWB_EXPECT(snapshot.resolve({-17, -16, -1}).has_value());
    VWB_EXPECT(snapshot.resolve({-16, -1, 0}).has_value());
    VWB_EXPECT(!snapshot.resolve({-18, -16, -1}).has_value());
    VWB_EXPECT(!snapshot.resolve({-15, -1, 0}).has_value());
    VWB_EXPECT_EQ(4U, snapshot.affected_sections().size());
}

VWB_TEST(generated_patch_canonical_manifest_is_arrival_order_invariant) {
    auto low = operation("alpha", 1U, {{0, 0, 0}, {2, 2, 2}});
    auto high = operation("omega", 2U, {{1, 1, 1}, {3, 3, 3}}, air_state());
    high.deterministic_order = 20U;
    const NativeGeneratedTerrainPatchManifest left = admit({low, high});
    const NativeGeneratedTerrainPatchManifest right = admit({high, low});
    VWB_EXPECT_EQ(left.canonical_binary(), right.canonical_binary());
    VWB_EXPECT_EQ(left.content_digest(), right.content_digest());
}

VWB_TEST(generated_patch_overlap_precedence_is_greater_order_then_owner_then_ordinal) {
    auto lower_order = operation("zeta", 9U, {{1, 1, 1}, {1, 1, 1}}, solid_state(TerrainMaterialId::stone));
    lower_order.deterministic_order = 9U;
    auto alpha = operation("alpha", 1U, {{1, 1, 1}, {1, 1, 1}}, solid_state(TerrainMaterialId::dirt));
    auto zeta_low_ordinal = operation("zeta", 1U, {{1, 1, 1}, {1, 1, 1}}, solid_state(TerrainMaterialId::clay));
    auto zeta_high_ordinal = operation("zeta", 2U, {{1, 1, 1}, {1, 1, 1}}, solid_state(TerrainMaterialId::gravel));
    const auto snapshot = NativeGeneratedTerrainPatchPageSnapshot::project(
        admit({zeta_high_ordinal, lower_order, zeta_low_ordinal, alpha}), page());
    const auto resolved = snapshot.resolve({1, 1, 1});
    VWB_EXPECT(resolved.has_value());
    VWB_EXPECT_EQ(TerrainMaterialId::gravel, resolved->state.material);
    VWB_EXPECT_EQ(std::string("zeta"), resolved->owner_feature_id);
    VWB_EXPECT_EQ(2U, resolved->operation_ordinal);
}

VWB_TEST(generated_patch_rejects_duplicate_conflicting_and_ambiguous_keys) {
    const auto base = operation("same", 1U);
    expect_failure(NativeGeneratedTerrainPatchFailure::duplicate_operation_identity,
        [&]() { static_cast<void>(admit({base, base})); });
    auto conflict = base;
    conflict.bounds.maximum.x = 1;
    expect_failure(NativeGeneratedTerrainPatchFailure::conflicting_operation_identity,
        [&]() { static_cast<void>(admit({base, conflict})); });
    auto ambiguous = base;
    ambiguous.recipe_revision = 8U;
    expect_failure(NativeGeneratedTerrainPatchFailure::mixed_owner_recipe_revision,
        [&]() { static_cast<void>(admit({base, ambiguous})); });
}

VWB_TEST(generated_patch_requires_one_recipe_revision_per_owner_across_complete_manifest) {
    auto revision_seven = operation("one-owner", 0U, {{0, 0, 0}, {0, 0, 0}});
    auto revision_eight = operation("one-owner", 99U, {{100, 100, 100}, {100, 100, 100}});
    revision_eight.recipe_revision = 8U;
    revision_eight.deterministic_order = 900U;
    expect_failure(NativeGeneratedTerrainPatchFailure::mixed_owner_recipe_revision,
        [&]() { static_cast<void>(admit({revision_seven, revision_eight})); });
    expect_failure(NativeGeneratedTerrainPatchFailure::mixed_owner_recipe_revision,
        [&]() { static_cast<void>(admit({revision_eight, revision_seven})); });
    revision_eight.owner_feature_id = "other-owner";
    VWB_EXPECT_EQ(2U, admit({revision_eight, revision_seven}).operations().size());
}

VWB_TEST(generated_patch_page_crop_crosses_seams_and_explicit_sixteen_cell_halo) {
    const auto crossing = operation("crossing", 0U, {{-2, -2, -2}, {18, 18, 18}});
    const auto distant = operation("distant", 1U, {{64, 64, 64}, {65, 65, 65}});
    const NativeGeneratedTerrainPatchManifest manifest = admit({distant, crossing});
    const auto without_halo = NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page());
    VWB_EXPECT_EQ(1U, without_halo.operations().size());
    VWB_EXPECT((without_halo.operations()[0].bounds == NativeInclusiveCellBox{{0, 0, 0}, {15, 15, 15}}));
    const auto with_halo = NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page({{0, 0, 0}, {15, 15, 15}}, 16U));
    VWB_EXPECT((with_halo.projected_bounds() == NativeInclusiveCellBox{{-16, -16, -16}, {31, 31, 31}}));
    VWB_EXPECT((with_halo.operations()[0].bounds == NativeInclusiveCellBox{{-2, -2, -2}, {18, 18, 18}}));
    VWB_EXPECT(with_halo.resolve({-2, -2, -2}).has_value());
    VWB_EXPECT(!with_halo.resolve({64, 64, 64}).has_value());
    auto horizontal_domain = page();
    horizontal_domain.mesh_halo = {16U, 0U, 16U};
    const auto horizontal_halo = NativeGeneratedTerrainPatchPageSnapshot::project(manifest, horizontal_domain);
    VWB_EXPECT((horizontal_halo.projected_bounds() == NativeInclusiveCellBox{{-16, 0, -16}, {31, 15, 31}}));
}

VWB_TEST(generated_patch_local_digest_ignores_distant_manifest_changes_and_global_revision) {
    const auto local = operation("local", 0U, {{0, 0, 0}, {1, 1, 1}});
    auto distant = operation("distant", 0U, {{100, 100, 100}, {101, 101, 101}});
    NativeGeneratedTerrainPatchManifestDescriptor left_input = descriptor({local}, 4U);
    NativeGeneratedTerrainPatchManifestDescriptor right_input = descriptor({distant, local}, 99U);
    const auto left = NativeGeneratedTerrainPatchManifest::admit(std::move(left_input));
    const auto right = NativeGeneratedTerrainPatchManifest::admit(std::move(right_input));
    VWB_EXPECT(left.content_digest() != right.content_digest());
    const auto left_page = NativeGeneratedTerrainPatchPageSnapshot::project(left, page());
    const auto right_page = NativeGeneratedTerrainPatchPageSnapshot::project(right, page());
    VWB_EXPECT_EQ(left_page.canonical_binary(), right_page.canonical_binary());
    VWB_EXPECT_EQ(left_page.projection_digest(), right_page.projection_digest());

    const auto unrelated_tombstone = NativeGeneratedTerrainPatchPageSnapshot::project(
        right, page(), {"distant"});
    VWB_EXPECT_EQ(right_page.projection_digest(), unrelated_tombstone.projection_digest());
}

VWB_TEST(generated_patch_tombstones_filter_only_declared_following_lifecycle) {
    auto permanent = operation("permanent", 0U, {{1, 1, 1}, {1, 1, 1}}, solid_state(TerrainMaterialId::stone));
    permanent.lifecycle = NativeGeneratedTerrainPatchLifecycle::permanent_site_shaping;
    auto following = operation("following", 0U, {{2, 2, 2}, {2, 2, 2}}, solid_state(TerrainMaterialId::clay));
    following.lifecycle = NativeGeneratedTerrainPatchLifecycle::follows_feature_tombstone;
    const auto manifest = admit({following, permanent});
    const auto snapshot = NativeGeneratedTerrainPatchPageSnapshot::project(
        manifest, page(), {"following", "permanent"});
    VWB_EXPECT(snapshot.resolve({1, 1, 1}).has_value());
    VWB_EXPECT(!snapshot.resolve({2, 2, 2}).has_value());
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_tombstone,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page(), {"unknown"})); });
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_tombstone,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page(), {"permanent", "permanent"})); });
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_tombstone,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page(), {""})); });
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_tombstone,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(
            manifest, page(), {std::string("bad\xc0\x80", 5)})); });
    std::vector<std::string> too_many_tombstones(
        NativeGeneratedTerrainPatchLimits::MAX_PAGE_TOMBSTONES + 1U, "following");
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_tombstone,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(
            manifest, page(), too_many_tombstones)); });
}

VWB_TEST(generated_patch_complete_manifest_is_independent_of_unloaded_page_projection) {
    const auto west = operation("west", 0U, {{-128, 0, 0}, {-120, 8, 8}});
    const auto east = operation("east", 0U, {{120, 0, 0}, {128, 8, 8}});
    const auto manifest = admit({east, west});
    const auto empty = NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page({{-16, 0, 0}, {-1, 15, 15}}));
    const auto east_page = NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page({{112, 0, 0}, {143, 15, 15}}));
    VWB_EXPECT(empty.operations().empty());
    VWB_EXPECT_EQ(1U, east_page.operations().size());
    VWB_EXPECT(east_page.resolve({128, 8, 8}).has_value());
    VWB_EXPECT_EQ(2U, manifest.operations().size());
}

VWB_TEST(generated_patch_page_requires_complete_expanded_domain_coverage) {
    NativeGeneratedTerrainPatchManifestDescriptor input = descriptor({operation("inside", 0U,
        {{0, 0, 0}, {31, 31, 31}})});
    input.complete_region_bounds = {{0, 0, 0}, {31, 31, 31}};
    const auto manifest = NativeGeneratedTerrainPatchManifest::admit(input);
    VWB_EXPECT_EQ(1U, NativeGeneratedTerrainPatchPageSnapshot::project(
        manifest, page({{0, 0, 0}, {15, 15, 15}})).operations().size());
    VWB_EXPECT_EQ(1U, NativeGeneratedTerrainPatchPageSnapshot::project(
        manifest, page({{16, 16, 16}, {31, 31, 31}})).operations().size());
    VWB_EXPECT_EQ(1U, NativeGeneratedTerrainPatchPageSnapshot::project(
        manifest, page({{1, 1, 1}, {30, 30, 30}}, 1U)).operations().size());
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_page_domain,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(
            manifest, page({{32, 0, 0}, {47, 15, 15}}))); });
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_page_domain,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(
            manifest, page({{-1, 0, 0}, {15, 15, 15}}))); });
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_page_domain,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(
            manifest, page({{0, 0, 0}, {15, 15, 15}}, 1U))); });
    auto cross_region = page({{16, 16, 16}, {31, 31, 31}});
    cross_region.mesh_halo = {1U, 0U, 1U};
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_page_domain,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, cross_region)); });
}

VWB_TEST(generated_patch_empty_manifest_is_complete_only_inside_its_region) {
    NativeGeneratedTerrainPatchManifestDescriptor input = descriptor({});
    input.complete_region_bounds = {{-16, -16, -16}, {15, 15, 15}};
    const auto manifest = NativeGeneratedTerrainPatchManifest::admit(input);
    VWB_EXPECT(manifest.operations().empty());
    VWB_EXPECT(manifest.affected_sections().empty());
    VWB_EXPECT(manifest.retained_bytes() > manifest.canonical_binary().size());
    const auto snapshot = NativeGeneratedTerrainPatchPageSnapshot::project(
        manifest, page({{-16, -16, -16}, {15, 15, 15}}));
    VWB_EXPECT(snapshot.operations().empty());
    VWB_EXPECT(snapshot.affected_sections().empty());
    VWB_EXPECT(!snapshot.resolve({0, 0, 0}).has_value());
    VWB_EXPECT(snapshot.retained_bytes() > snapshot.canonical_binary().size());
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_page_domain,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(
            manifest, page({{16, -16, -16}, {31, 15, 15}}))); });
}

VWB_TEST(generated_patch_admission_and_projection_are_immutable_after_caller_mutation) {
    NativeGeneratedTerrainPatchManifestDescriptor input = descriptor({operation("immutable", 0U)});
    input.complete_region_bounds = {{0, 0, 0}, {15, 15, 15}};
    const auto manifest = NativeGeneratedTerrainPatchManifest::admit(input);
    const auto manifest_digest = manifest.content_digest();
    input.region_id = "mutated";
    input.operations[0].owner_feature_id = "mutated";
    input.operations[0].state.density = 99.0;
    input.operations.clear();
    VWB_EXPECT_EQ(std::string("region:test"), manifest.region_id());
    VWB_EXPECT_EQ(std::string("immutable"), manifest.operations()[0].owner_feature_id);
    VWB_EXPECT_EQ(1.35, manifest.operations()[0].state.density);
    VWB_EXPECT_EQ(manifest_digest, manifest.content_digest());

    NativeGeneratedTerrainPageDomain caller_domain = page();
    std::vector<std::string> caller_tombstones;
    const auto snapshot = NativeGeneratedTerrainPatchPageSnapshot::project(
        manifest, caller_domain, caller_tombstones);
    const auto projection_digest = snapshot.projection_digest();
    caller_domain.page_id = "mutated";
    caller_domain.owned_bounds = {{8, 8, 8}, {9, 9, 9}};
    caller_tombstones.push_back("immutable");
    VWB_EXPECT_EQ(std::string("page:test"), snapshot.domain().page_id);
    VWB_EXPECT((snapshot.domain().owned_bounds == NativeInclusiveCellBox{{0, 0, 0}, {15, 15, 15}}));
    VWB_EXPECT(snapshot.resolve({0, 0, 0}).has_value());
    VWB_EXPECT_EQ(projection_digest, snapshot.projection_digest());
}

VWB_TEST(generated_patch_rejects_invalid_manifest_identity_revisions_region_and_operation_fields) {
    NativeGeneratedTerrainPatchManifestDescriptor input = descriptor({operation("valid", 0U)});
    input.world_physical_identity = {};
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_source_identity,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });
    input = descriptor({operation("valid", 0U)}); input.schema_revision = 2U;
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_schema_revision,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });
    input = descriptor({operation("valid", 0U)}); input.producer_revision = 0U;
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_producer_revision,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });
    input = descriptor({operation("valid", 0U)}); input.feature_source_revision = 0U;
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_feature_source_revision,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });
    input = descriptor({operation("valid", 0U)}); input.region_id.clear();
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_text,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });
    input = descriptor({operation("valid", 0U)}); input.region_id = std::string("bad\xf5", 4);
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_text,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });
    input = descriptor({operation("valid", 0U)}); input.region_id.assign(NativeGeneratedTerrainPatchLimits::MAX_TEXT_FIELD_BYTES + 1U, 'r');
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_text,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });
    input = descriptor({operation("valid", 0U)}); input.complete_region_bounds = {{1, 0, 0}, {0, 0, 0}};
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_region,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });
    input = descriptor({operation("valid", 0U)}); input.complete_region_bounds = {{0, 1, 0}, {0, 0, 0}};
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_region,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });
    input = descriptor({operation("valid", 0U)}); input.complete_region_bounds = {{0, 0, 1}, {0, 0, 0}};
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_region,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });
    input = descriptor({operation("valid", 0U, {{0, 0, 0}, {1, 0, 0}})}); input.complete_region_bounds = {{0, 0, 0}, {0, 0, 0}};
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_region,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });
    input = descriptor({operation("valid", 0U, {{-1, 0, 0}, {0, 0, 0}})}); input.complete_region_bounds = {{0, 0, 0}, {1, 1, 1}};
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_region,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(input)); });

    auto bad = operation("valid", 0U); bad.source_layer = NativeTerrainSourceLayer::natural_generated;
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_source_layer, [&]() { static_cast<void>(admit({bad})); });
    bad = operation("valid", 0U); bad.source_layer = NativeTerrainSourceLayer::durable_terrain_override;
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_source_layer, [&]() { static_cast<void>(admit({bad})); });
    bad = operation("valid", 0U); bad.recipe_revision = 0U;
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_recipe_revision, [&]() { static_cast<void>(admit({bad})); });
    bad = operation("valid", 0U); bad.role = static_cast<NativeGeneratedTerrainPatchRole>(0xffU);
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_role, [&]() { static_cast<void>(admit({bad})); });
    bad = operation("valid", 0U); bad.lifecycle = static_cast<NativeGeneratedTerrainPatchLifecycle>(0xffU);
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_lifecycle, [&]() { static_cast<void>(admit({bad})); });
    bad = operation("", 0U);
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_text, [&]() { static_cast<void>(admit({bad})); });
    bad = operation(std::string("bad\xc0\x80", 5), 0U);
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_text, [&]() { static_cast<void>(admit({bad})); });
    bad = operation(std::string(NativeGeneratedTerrainPatchLimits::MAX_TEXT_FIELD_BYTES + 1U, 'x'), 0U);
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_text, [&]() { static_cast<void>(admit({bad})); });
    bad = operation("valid", 0U); bad.bounds = {{1, 0, 0}, {0, 0, 0}};
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_box, [&]() { static_cast<void>(admit({bad})); });
}

VWB_TEST(generated_patch_validates_exact_cell_state_semantics) {
    NativeGeneratedTerrainCellTemplate state = solid_state();
    state.block_identity = "building.foundation";
    state.light = {15U, 15U};
    state.metadata = NativeValue::object({
        {"false", NativeValue::boolean(false)},
        {"number", NativeValue::number(42.5)},
        {"true", NativeValue::boolean(true)},
    });
    auto valid = operation("valid", 0U, {{0, 0, 0}, {0, 0, 0}}, state);
    VWB_EXPECT_EQ(std::string("building.foundation"), admit({valid}).operations()[0].state.block_identity.value());

    std::vector<NativeGeneratedTerrainCellTemplate> invalid;
    state = solid_state(); state.material = static_cast<TerrainMaterialId>(0xffU); invalid.push_back(state);
    state = solid_state(); state.biome = static_cast<TerrainBiomeId>(0xffU); invalid.push_back(state);
    state = solid_state(); state.fluid = static_cast<TerrainFluidId>(0xffU); invalid.push_back(state);
    state = solid_state(); state.density = std::numeric_limits<double>::quiet_NaN(); invalid.push_back(state);
    state = solid_state(); state.light.sky = 16U; invalid.push_back(state);
    state = solid_state(); state.light.block = 16U; invalid.push_back(state);
    state = solid_state(); state.solid = false; invalid.push_back(state);
    state = air_state(); state.solid = true; invalid.push_back(state);
    state = solid_state(); state.fluid = TerrainFluidId::water; invalid.push_back(state);
    state = air_state(); state.fluid = TerrainFluidId::water; invalid.push_back(state);
    state = air_state(); state.fluid = TerrainFluidId::lava; invalid.push_back(state);
    state = air_state(); state.material = TerrainMaterialId::water; invalid.push_back(state);
    state = air_state(); state.material = TerrainMaterialId::lava; invalid.push_back(state);
    state = solid_state(); state.material = TerrainMaterialId::air; invalid.push_back(state);
    state = air_state(); state.density = 0.0; invalid.push_back(state);
    state = air_state(); state.material = TerrainMaterialId::water; state.fluid = TerrainFluidId::water; state.density = 0.0; invalid.push_back(state);
    state = air_state(); state.material = TerrainMaterialId::lava; state.fluid = TerrainFluidId::lava; state.density = 0.0; invalid.push_back(state);
    state = air_state(); state.metadata = NativeValue::array({}); invalid.push_back(state);
    for (std::size_t index = 0U; index < invalid.size(); ++index) {
        expect_failure(NativeGeneratedTerrainPatchFailure::invalid_cell_state,
            [&]() { static_cast<void>(admit({operation("bad:" + std::to_string(index), 0U,
                {{0, 0, 0}, {0, 0, 0}}, invalid[index])})); });
    }

    state = solid_state(); state.block_identity = "";
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_text,
        [&]() { static_cast<void>(admit({operation("empty-block", 0U, {{0, 0, 0}, {0, 0, 0}}, state)})); });
    state = solid_state(); state.block_identity = std::string("bad\xf5", 4);
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_text,
        [&]() { static_cast<void>(admit({operation("bad-block", 0U, {{0, 0, 0}, {0, 0, 0}}, state)})); });

    state = solid_state();
    VWB_EXPECT(NativeValueTestAccess::force_valueless_by_exception(state.metadata));
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_cell_state,
        [&]() { static_cast<void>(admit({operation("bad-metadata", 0U, {{0, 0, 0}, {0, 0, 0}}, state)})); });

    auto wrong_role = operation("solid-interior", 0U);
    wrong_role.role = NativeGeneratedTerrainPatchRole::interior_clearance;
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_cell_state,
        [&]() { static_cast<void>(admit({wrong_role})); });
    state = air_state(); state.density = 0.0; state.material = TerrainMaterialId::water; state.fluid = TerrainFluidId::water;
    wrong_role = operation("zero-interior", 0U, {{0, 0, 0}, {0, 0, 0}}, state);
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_cell_state,
        [&]() { static_cast<void>(admit({wrong_role})); });
    state = air_state(); state.material = TerrainMaterialId::dirt;
    wrong_role = operation("material-interior", 0U, {{0, 0, 0}, {0, 0, 0}}, state);
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_cell_state,
        [&]() { static_cast<void>(admit({wrong_role})); });
    state = air_state(); state.block_identity = "unexpected.block";
    wrong_role = operation("block-interior", 0U, {{0, 0, 0}, {0, 0, 0}}, state);
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_cell_state,
        [&]() { static_cast<void>(admit({wrong_role})); });
    wrong_role = operation("air-foundation", 0U, {{0, 0, 0}, {0, 0, 0}}, air_state());
    wrong_role.role = NativeGeneratedTerrainPatchRole::foundation_fill;
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_cell_state,
        [&]() { static_cast<void>(admit({wrong_role})); });
    state = solid_state(); state.density = 0.0;
    wrong_role = operation("zero-foundation", 0U, {{0, 0, 0}, {0, 0, 0}}, state);
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_cell_state,
        [&]() { static_cast<void>(admit({wrong_role})); });
}

VWB_TEST(generated_patch_rejects_every_persistence_mesh_projection_and_overlay_metadata_policy) {
    const std::vector<std::string> forbidden = {
        "saveDelta", "terrainMeshAffects", "affectsTerrainMesh", "affectsSurfaceProjection", "surfaceProjectionAffects",
        "renderedBySceneBlock", "persistsInSave", "persistence", "namespace"};
    for (const std::string &key : forbidden) {
        NativeGeneratedTerrainCellTemplate state = solid_state();
        state.metadata = NativeValue::object({{key, NativeValue::boolean(true)}});
        expect_failure(NativeGeneratedTerrainPatchFailure::forbidden_policy_metadata,
            [&]() { static_cast<void>(admit({operation("bad-policy", 0U, {{0, 0, 0}, {0, 0, 0}}, state)})); });
    }
}

VWB_TEST(generated_patch_checked_volume_aggregate_and_section_limits_fail_closed) {
    auto exact_volume = operation("exact-volume", 0U, {{0, 0, 0}, {255, 127, 127}});
    VWB_EXPECT_EQ(1U, admit({exact_volume}).operations().size());
    auto over_volume = operation("over-volume", 0U, {{0, 0, 0}, {256, 127, 127}});
    expect_failure(NativeGeneratedTerrainPatchFailure::operation_volume_limit,
        [&]() { static_cast<void>(admit({over_volume})); });
    for (const NativeInclusiveCellBox bounds : std::vector<NativeInclusiveCellBox>{
            {{0, 0, 0}, {static_cast<std::int32_t>(NativeGeneratedTerrainPatchLimits::MAX_OPERATION_CELL_VOLUME), 0, 0}},
            {{0, 0, 0}, {0, static_cast<std::int32_t>(NativeGeneratedTerrainPatchLimits::MAX_OPERATION_CELL_VOLUME), 0}},
            {{0, 0, 0}, {0, 0, static_cast<std::int32_t>(NativeGeneratedTerrainPatchLimits::MAX_OPERATION_CELL_VOLUME)}}}) {
        expect_failure(NativeGeneratedTerrainPatchFailure::operation_volume_limit,
            [&]() { static_cast<void>(admit({operation("axis-over", 0U, bounds)})); });
    }
    auto overflow = operation("overflow", 0U, {{0, 0, 0}, {4194303, 4194303, 4194303}});
    expect_failure(NativeGeneratedTerrainPatchFailure::coordinate_overflow,
        [&]() { static_cast<void>(admit({overflow})); });

    std::vector<NativeGeneratedTerrainPatchOperation> aggregate;
    for (std::uint32_t index = 0U; index < 16U; ++index) {
        aggregate.push_back(operation("aggregate:" + std::to_string(index), 0U,
            {{0, 0, 0}, {255, 127, 127}}));
    }
    VWB_EXPECT_EQ(16U, admit(aggregate).operations().size());
    aggregate.push_back(operation("aggregate:16", 0U, {{0, 0, 0}, {255, 127, 127}}));
    expect_failure(NativeGeneratedTerrainPatchFailure::aggregate_volume_limit,
        [&]() { static_cast<void>(admit(aggregate)); });

    auto exact_sections = operation("sections", 0U,
        {{0, 0, 0}, {static_cast<std::int32_t>(NativeGeneratedTerrainPatchLimits::MAX_AFFECTED_SECTIONS * 16U - 1U), 0, 0}});
    VWB_EXPECT_EQ(NativeGeneratedTerrainPatchLimits::MAX_AFFECTED_SECTIONS,
        admit({exact_sections}).affected_sections().size());
    auto over_sections = exact_sections;
    over_sections.bounds.maximum.x += 16;
    expect_failure(NativeGeneratedTerrainPatchFailure::affected_sections_limit,
        [&]() { static_cast<void>(admit({over_sections})); });
}

VWB_TEST(generated_patch_operation_count_and_utf8_caps_are_bounded_before_admission) {
    std::vector<NativeGeneratedTerrainPatchOperation> exact;
    exact.reserve(NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_OPERATIONS);
    for (std::uint32_t index = 0U; index < NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_OPERATIONS; ++index) {
        exact.push_back(operation("op:" + std::to_string(index), index));
    }
    VWB_EXPECT_EQ(NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_OPERATIONS, admit(exact).operations().size());
    exact.push_back(operation("over", 99999U));
    expect_failure(NativeGeneratedTerrainPatchFailure::operation_count_limit,
        [&]() { static_cast<void>(admit(exact)); });

    std::vector<NativeGeneratedTerrainPatchOperation> utf8_heavy;
    for (std::uint32_t index = 0U; index < 17U; ++index) {
        NativeGeneratedTerrainCellTemplate state = solid_state();
        state.metadata = NativeValue::object({{"description", NativeValue::string(
            std::string(NativeValueLimits::MAX_STRING_BYTES, static_cast<char>('a' + index)))}});
        utf8_heavy.push_back(operation("utf8:" + std::to_string(index), index,
            {{0, 0, 0}, {0, 0, 0}}, std::move(state)));
    }
    expect_failure(NativeGeneratedTerrainPatchFailure::utf8_bytes_limit,
        [&]() { static_cast<void>(admit(utf8_heavy)); });
}

VWB_TEST(generated_patch_canonical_and_page_retained_byte_caps_are_enforced) {
    NativeValue::Array roomy_values;
    roomy_values.reserve(100000U);
    roomy_values.push_back(NativeValue::null());
    NativeValue::Object roomy_metadata;
    roomy_metadata.reserve(10000U);
    roomy_metadata.emplace_back("values", NativeValue::array(std::move(roomy_values)));
    NativeGeneratedTerrainCellTemplate roomy_state = solid_state();
    roomy_state.metadata = NativeValue::object(std::move(roomy_metadata));
    std::string roomy_owner(10000U, 'x');
    roomy_owner.resize(16U);
    roomy_owner.back() = '1';
    std::vector<NativeGeneratedTerrainPatchOperation> roomy_operations;
    roomy_operations.reserve(10000U);
    roomy_operations.push_back(operation(std::move(roomy_owner), 0U,
        {{0, 0, 0}, {0, 0, 0}}, std::move(roomy_state)));
    roomy_operations[0].lifecycle = NativeGeneratedTerrainPatchLifecycle::follows_feature_tombstone;
    NativeGeneratedTerrainPatchManifestDescriptor roomy_descriptor = descriptor(std::move(roomy_operations));
    roomy_descriptor.region_id.assign(10000U, 'r');
    roomy_descriptor.region_id.resize(16U);
    NativeGeneratedTerrainPatchManifestDescriptor compact_descriptor = roomy_descriptor;
    VWB_EXPECT(roomy_descriptor.operations.capacity() > compact_descriptor.operations.capacity());
    VWB_EXPECT(roomy_descriptor.operations[0].state.metadata.as_object().capacity()
        > compact_descriptor.operations[0].state.metadata.as_object().capacity());
    const auto roomy_manifest = NativeGeneratedTerrainPatchManifest::admit(roomy_descriptor);
    const auto compact_manifest = NativeGeneratedTerrainPatchManifest::admit(compact_descriptor);
    VWB_EXPECT_EQ(roomy_manifest.canonical_binary(), compact_manifest.canonical_binary());
    VWB_EXPECT_EQ(roomy_manifest.content_digest(), compact_manifest.content_digest());
    VWB_EXPECT_EQ(roomy_manifest.retained_bytes(), compact_manifest.retained_bytes());
    VWB_EXPECT_EQ(roomy_manifest.peak_working_bytes(), compact_manifest.peak_working_bytes());
    VWB_EXPECT(roomy_manifest.operations().capacity() <= roomy_manifest.operations().size());

    NativeGeneratedTerrainPageDomain roomy_domain = page();
    roomy_domain.page_id.assign(10000U, 'p');
    roomy_domain.page_id.resize(16U);
    NativeGeneratedTerrainPageDomain compact_domain = roomy_domain;
    const auto roomy_page = NativeGeneratedTerrainPatchPageSnapshot::project(roomy_manifest, roomy_domain);
    const auto compact_page = NativeGeneratedTerrainPatchPageSnapshot::project(compact_manifest, compact_domain);
    VWB_EXPECT_EQ(roomy_page.canonical_binary(), compact_page.canonical_binary());
    VWB_EXPECT_EQ(roomy_page.projection_digest(), compact_page.projection_digest());
    VWB_EXPECT_EQ(roomy_page.retained_bytes(), compact_page.retained_bytes());
    VWB_EXPECT_EQ(roomy_page.peak_working_bytes(), compact_page.peak_working_bytes());

    std::string roomy_tombstone(10000U, 'x');
    roomy_tombstone.resize(16U);
    roomy_tombstone.back() = '1';
    std::vector<std::string> roomy_tombstones;
    roomy_tombstones.reserve(10000U);
    roomy_tombstones.push_back(std::move(roomy_tombstone));
    const std::vector<std::string> compact_tombstones = roomy_tombstones;
    const auto roomy_tombstoned_page = NativeGeneratedTerrainPatchPageSnapshot::project(
        roomy_manifest, roomy_domain, roomy_tombstones);
    const auto compact_tombstoned_page = NativeGeneratedTerrainPatchPageSnapshot::project(
        compact_manifest, compact_domain, compact_tombstones);
    VWB_EXPECT_EQ(roomy_tombstoned_page.projection_digest(), compact_tombstoned_page.projection_digest());
    VWB_EXPECT_EQ(roomy_tombstoned_page.retained_bytes(), compact_tombstoned_page.retained_bytes());
    VWB_EXPECT_EQ(roomy_tombstoned_page.peak_working_bytes(), compact_tombstoned_page.peak_working_bytes());

    roomy_descriptor.operations.resize(NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_OPERATIONS + 1U,
        roomy_descriptor.operations[0]);
    compact_descriptor = roomy_descriptor;
    expect_failure(NativeGeneratedTerrainPatchFailure::operation_count_limit,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(roomy_descriptor)); });
    expect_failure(NativeGeneratedTerrainPatchFailure::operation_count_limit,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchManifest::admit(compact_descriptor)); });

    const NativeValue bulky = numeric_metadata();
    std::vector<NativeGeneratedTerrainPatchOperation> canonical_heavy;
    canonical_heavy.reserve(920U);
    for (std::uint32_t index = 0U; index < 920U; ++index) {
        NativeGeneratedTerrainCellTemplate state = solid_state();
        state.metadata = bulky;
        canonical_heavy.push_back(operation("canonical:" + std::to_string(index), index,
            {{0, 0, 0}, {0, 0, 0}}, std::move(state)));
    }
    expect_failure(NativeGeneratedTerrainPatchFailure::canonical_bytes_limit,
        [&]() { static_cast<void>(admit(canonical_heavy)); });

    // A null encodes as one byte but occupies a complete NativeValue node.
    // The retained cap must therefore reject this adversarial shape long
    // before its canonical-byte cap is reached.
    expect_failure(NativeGeneratedTerrainPatchFailure::manifest_retained_bytes_limit,
        [&]() { static_cast<void>(admit(null_array_operations(400U))); });

    std::vector<NativeGeneratedTerrainPatchOperation> object_heavy;
    object_heavy.reserve(210U);
    const NativeValue object_metadata = null_object_metadata();
    NativeGeneratedTerrainCellTemplate one_object_state = solid_state();
    one_object_state.metadata = object_metadata;
    const auto one_object_manifest = admit({operation("object-retained:single", 0U,
        {{0, 0, 0}, {0, 0, 0}}, std::move(one_object_state))});
    VWB_EXPECT(one_object_manifest.retained_bytes() > one_object_manifest.canonical_binary().size() * 4U);
    for (std::uint32_t index = 0U; index < 210U; ++index) {
        NativeGeneratedTerrainCellTemplate state = solid_state();
        state.metadata = object_metadata;
        object_heavy.push_back(operation("object-retained:" + std::to_string(index), index,
            {{0, 0, 0}, {0, 0, 0}}, std::move(state)));
    }
    expect_failure(NativeGeneratedTerrainPatchFailure::canonical_bytes_limit,
        [&]() { static_cast<void>(admit(object_heavy)); });

    auto prepare_tunable_owners = [](std::vector<NativeGeneratedTerrainPatchOperation> &operations) {
        for (std::size_t index = 0U; index < 3U; ++index) {
            operations[index].owner_feature_id = std::string(15U, static_cast<char>('a' + index));
            operations[index].owner_feature_id.push_back(static_cast<char>('0' + index));
        }
    };
    auto distribute_owner_padding = [&](std::vector<NativeGeneratedTerrainPatchOperation> &operations,
                                        std::size_t padding) {
        for (std::size_t index = 0U; index < 3U && padding != 0U; ++index) {
            const std::size_t amount = std::min<std::size_t>(15U, padding);
            operations[index].owner_feature_id.append(amount, 'x');
            padding -= amount;
        }
        VWB_EXPECT_EQ(0U, padding);
    };

    constexpr std::size_t MANIFEST_OPERATION_COUNT = 300U;
    auto manifest_base_operations = null_array_operations(MANIFEST_OPERATION_COUNT);
    prepare_tunable_owners(manifest_base_operations);
    const auto manifest_base = admit(manifest_base_operations);
    auto manifest_one_full_operations = null_array_operations(MANIFEST_OPERATION_COUNT, 1U);
    prepare_tunable_owners(manifest_one_full_operations);
    const auto manifest_one_full = admit(manifest_one_full_operations);
    const std::size_t manifest_full_delta = manifest_one_full.retained_bytes() - manifest_base.retained_bytes();
    const std::size_t manifest_full_count =
        (NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_RETAINED_BYTES - manifest_base.retained_bytes())
        / manifest_full_delta;
    auto manifest_full_operations = null_array_operations(MANIFEST_OPERATION_COUNT, manifest_full_count);
    prepare_tunable_owners(manifest_full_operations);
    const auto manifest_full = admit(manifest_full_operations);
    auto manifest_one_node_operations = null_array_operations(MANIFEST_OPERATION_COUNT, manifest_full_count, 1U);
    prepare_tunable_owners(manifest_one_node_operations);
    const auto manifest_one_node = admit(manifest_one_node_operations);
    auto manifest_two_node_operations = null_array_operations(MANIFEST_OPERATION_COUNT, manifest_full_count, 2U);
    prepare_tunable_owners(manifest_two_node_operations);
    const auto manifest_two_node = admit(manifest_two_node_operations);
    const std::size_t manifest_first_node_delta =
        manifest_one_node.retained_bytes() - manifest_full.retained_bytes();
    const std::size_t manifest_additional_node_delta =
        manifest_two_node.retained_bytes() - manifest_one_node.retained_bytes();
    const std::size_t manifest_remaining_after_full =
        NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_RETAINED_BYTES - manifest_full.retained_bytes();
    const std::size_t manifest_partial_count = 1U
        + (manifest_remaining_after_full - manifest_first_node_delta) / manifest_additional_node_delta;
    auto manifest_exact_operations = null_array_operations(
        MANIFEST_OPERATION_COUNT, manifest_full_count, manifest_partial_count);
    prepare_tunable_owners(manifest_exact_operations);
    const auto manifest_partial = admit(manifest_exact_operations);
    const std::size_t manifest_owner_padding =
        NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_RETAINED_BYTES - manifest_partial.retained_bytes();
    VWB_EXPECT(manifest_owner_padding <= 45U);
    distribute_owner_padding(manifest_exact_operations, manifest_owner_padding);
    const auto exact_retained_manifest = admit(manifest_exact_operations);
    VWB_EXPECT_EQ(NativeGeneratedTerrainPatchLimits::MAX_MANIFEST_RETAINED_BYTES,
        exact_retained_manifest.retained_bytes());
    manifest_exact_operations[0].owner_feature_id.push_back('z');
    expect_failure(NativeGeneratedTerrainPatchFailure::manifest_retained_bytes_limit,
        [&]() { static_cast<void>(admit(manifest_exact_operations)); });

    constexpr std::size_t PAGE_OPERATION_COUNT = 80U;
    auto page_base_operations = null_array_operations(PAGE_OPERATION_COUNT);
    prepare_tunable_owners(page_base_operations);
    const auto page_base_manifest = admit(page_base_operations);
    const auto page_base = NativeGeneratedTerrainPatchPageSnapshot::project(page_base_manifest, page());
    auto page_one_full_operations = null_array_operations(PAGE_OPERATION_COUNT, 1U);
    prepare_tunable_owners(page_one_full_operations);
    const auto page_one_full_manifest = admit(page_one_full_operations);
    const auto page_one_full = NativeGeneratedTerrainPatchPageSnapshot::project(page_one_full_manifest, page());
    const std::size_t page_full_delta = page_one_full.retained_bytes() - page_base.retained_bytes();
    const std::size_t page_full_count =
        (NativeGeneratedTerrainPatchLimits::MAX_PAGE_RETAINED_BYTES - page_base.retained_bytes()) / page_full_delta;
    auto page_full_operations = null_array_operations(PAGE_OPERATION_COUNT, page_full_count);
    prepare_tunable_owners(page_full_operations);
    const auto page_full_manifest = admit(page_full_operations);
    const auto page_full = NativeGeneratedTerrainPatchPageSnapshot::project(page_full_manifest, page());
    auto page_one_node_operations = null_array_operations(PAGE_OPERATION_COUNT, page_full_count, 1U);
    prepare_tunable_owners(page_one_node_operations);
    const auto page_one_node_manifest = admit(page_one_node_operations);
    const auto page_one_node = NativeGeneratedTerrainPatchPageSnapshot::project(page_one_node_manifest, page());
    auto page_two_node_operations = null_array_operations(PAGE_OPERATION_COUNT, page_full_count, 2U);
    prepare_tunable_owners(page_two_node_operations);
    const auto page_two_node_manifest = admit(page_two_node_operations);
    const auto page_two_node = NativeGeneratedTerrainPatchPageSnapshot::project(page_two_node_manifest, page());
    const std::size_t page_first_node_delta = page_one_node.retained_bytes() - page_full.retained_bytes();
    const std::size_t page_additional_node_delta = page_two_node.retained_bytes() - page_one_node.retained_bytes();
    const std::size_t page_remaining_after_full =
        NativeGeneratedTerrainPatchLimits::MAX_PAGE_RETAINED_BYTES - page_full.retained_bytes();
    const std::size_t page_partial_count = 1U
        + (page_remaining_after_full - page_first_node_delta) / page_additional_node_delta;
    auto page_exact_operations = null_array_operations(PAGE_OPERATION_COUNT, page_full_count, page_partial_count);
    prepare_tunable_owners(page_exact_operations);
    const auto page_partial_manifest = admit(page_exact_operations);
    const auto page_partial = NativeGeneratedTerrainPatchPageSnapshot::project(page_partial_manifest, page());
    const std::size_t page_owner_padding =
        NativeGeneratedTerrainPatchLimits::MAX_PAGE_RETAINED_BYTES - page_partial.retained_bytes();
    VWB_EXPECT(page_owner_padding <= 45U);
    distribute_owner_padding(page_exact_operations, page_owner_padding);
    const auto page_exact_manifest = admit(page_exact_operations);
    const auto exact_page = NativeGeneratedTerrainPatchPageSnapshot::project(page_exact_manifest, page());
    VWB_EXPECT_EQ(NativeGeneratedTerrainPatchLimits::MAX_PAGE_RETAINED_BYTES, exact_page.retained_bytes());
    page_exact_operations[0].owner_feature_id.push_back('z');
    const auto page_over_manifest = admit(page_exact_operations);
    expect_failure(NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(page_over_manifest, page())); });
}

VWB_TEST(generated_patch_page_validates_domain_halo_tombstone_and_coordinate_overflow) {
    const auto manifest = admit({operation("valid", 0U)});
    auto domain = page(); domain.page_id.clear();
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_text,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, domain)); });
    domain = page(); domain.owned_bounds = {{1, 0, 0}, {0, 0, 0}};
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_page_domain,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, domain)); });
    domain = page(); domain.mesh_halo.x = 17U;
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_halo,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, domain)); });
    domain = page(); domain.mesh_halo.y = 17U;
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_halo,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, domain)); });
    domain = page(); domain.mesh_halo.z = 17U;
    expect_failure(NativeGeneratedTerrainPatchFailure::invalid_halo,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, domain)); });

    const std::int32_t low = std::numeric_limits<std::int32_t>::min();
    const std::int32_t high = std::numeric_limits<std::int32_t>::max();
    const std::vector<NativeInclusiveCellBox> overflow_domains = {
        {{low, 0, 0}, {0, 0, 0}}, {{0, low, 0}, {0, 0, 0}}, {{0, 0, low}, {0, 0, 0}},
        {{0, 0, 0}, {high, 0, 0}}, {{0, 0, 0}, {0, high, 0}}, {{0, 0, 0}, {0, 0, high}}};
    for (const auto &bounds : overflow_domains) {
        expect_failure(NativeGeneratedTerrainPatchFailure::coordinate_overflow,
            [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page(bounds, 1U))); });
    }
}

VWB_TEST(generated_patch_peak_working_caps_preflight_sections_and_projected_references) {
    std::vector<NativeGeneratedTerrainPatchOperation> excessive_section_emissions;
    for (std::uint32_t index = 0U; index < 3U; ++index) {
        excessive_section_emissions.push_back(operation("section-emission:" + std::to_string(index), index,
            {{0, 0, 0}, {100000 * NativeGeneratedTerrainPatchLimits::SECTION_SIZE - 1, 0, 0}}));
    }
    expect_failure(NativeGeneratedTerrainPatchFailure::manifest_peak_working_bytes_limit,
        [&]() { static_cast<void>(admit(excessive_section_emissions)); });

    auto manifest_peak = null_array_operations(280U);
    auto long_thin = operation("section-working", 999U,
        {{0, 0, 0}, {261800 * NativeGeneratedTerrainPatchLimits::SECTION_SIZE - 1, 0, 0}});
    manifest_peak.push_back(std::move(long_thin));
    expect_failure(NativeGeneratedTerrainPatchFailure::manifest_peak_working_bytes_limit,
        [&]() { static_cast<void>(admit(manifest_peak)); });

    std::vector<NativeGeneratedTerrainPatchOperation> page_peak;
    page_peak.reserve(NativeGeneratedTerrainPatchLimits::MAX_PAGE_PROJECTED_OPERATIONS);
    for (std::uint32_t index = 0U;
         index < NativeGeneratedTerrainPatchLimits::MAX_PAGE_PROJECTED_OPERATIONS; ++index) {
        page_peak.push_back(operation("page-peak:" + std::to_string(index), index,
            {{0, 0, 0}, {2047, 0, 0}}));
    }
    const auto manifest = admit(page_peak);
    NativeGeneratedTerrainPageDomain wide_page = page({{0, 0, 0}, {2047, 0, 0}});
    expect_failure(NativeGeneratedTerrainPatchFailure::page_peak_working_bytes_limit,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, wide_page)); });
}

VWB_TEST(generated_patch_page_operation_and_projected_volume_caps_are_enforced) {
    std::vector<NativeGeneratedTerrainPatchOperation> operations;
    operations.reserve(NativeGeneratedTerrainPatchLimits::MAX_PAGE_PROJECTED_OPERATIONS + 1U);
    for (std::uint32_t index = 0U; index <= NativeGeneratedTerrainPatchLimits::MAX_PAGE_PROJECTED_OPERATIONS; ++index) {
        operations.push_back(operation("page-op:" + std::to_string(index), index));
    }
    const auto manifest = admit(operations);
    expect_failure(NativeGeneratedTerrainPatchFailure::page_operation_limit,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page())); });
    operations.resize(NativeGeneratedTerrainPatchLimits::MAX_PAGE_PROJECTED_OPERATIONS);
    VWB_EXPECT_EQ(NativeGeneratedTerrainPatchLimits::MAX_PAGE_PROJECTED_OPERATIONS,
        NativeGeneratedTerrainPatchPageSnapshot::project(admit(operations), page()).operations().size());

    std::vector<NativeGeneratedTerrainPatchOperation> volume;
    for (std::uint32_t index = 0U; index < 3U; ++index) {
        volume.push_back(operation("page-volume:" + std::to_string(index), index,
            {{0, 0, 0}, {255, 127, 127}}));
    }
    const auto volume_manifest = admit(volume);
    expect_failure(NativeGeneratedTerrainPatchFailure::page_volume_limit,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(
            volume_manifest, page({{0, 0, 0}, {255, 127, 127}}))); });
}

VWB_TEST(generated_patch_value_equality_and_empty_resolution_paths_are_explicit) {
    volatile std::uint8_t natural = static_cast<std::uint8_t>(NativeTerrainSourceLayer::natural_generated);
    volatile std::uint8_t generated = static_cast<std::uint8_t>(NativeTerrainSourceLayer::generated_feature_terrain);
    volatile std::uint8_t durable = static_cast<std::uint8_t>(NativeTerrainSourceLayer::durable_terrain_override);
    VWB_EXPECT(natural < generated);
    VWB_EXPECT(generated < durable);
    const NativeInclusiveCellBox box{{0, 0, 0}, {1, 1, 1}};
    VWB_EXPECT(box == box);
    VWB_EXPECT(!(box == NativeInclusiveCellBox{{1, 0, 0}, {1, 1, 1}}));
    VWB_EXPECT(box.contains({0, 0, 0}));
    VWB_EXPECT(!box.contains({-1, 0, 0}));
    VWB_EXPECT(!box.contains({0, -1, 0}));
    VWB_EXPECT(!box.contains({0, 0, -1}));
    VWB_EXPECT(!box.contains({2, 0, 0}));
    VWB_EXPECT(!box.contains({0, 2, 0}));
    VWB_EXPECT(!box.contains({0, 0, 2}));
    VWB_EXPECT((NativeGeneratedTerrainLight{1, 2} == NativeGeneratedTerrainLight{1, 2}));
    VWB_EXPECT(!(NativeGeneratedTerrainLight{1, 2} == NativeGeneratedTerrainLight{2, 2}));
    VWB_EXPECT(!(NativeGeneratedTerrainLight{1, 2} == NativeGeneratedTerrainLight{1, 3}));
    const NativeGeneratedTerrainCellTemplate baseline_state = solid_state();
    VWB_EXPECT(baseline_state == solid_state());
    std::vector<NativeGeneratedTerrainCellTemplate> changed_states;
    auto changed_state = baseline_state; changed_state.material = TerrainMaterialId::stone; changed_states.push_back(changed_state);
    changed_state = baseline_state; changed_state.biome = TerrainBiomeId::forest; changed_states.push_back(changed_state);
    changed_state = baseline_state; changed_state.solid = false; changed_states.push_back(changed_state);
    changed_state = baseline_state; changed_state.density = 2.0; changed_states.push_back(changed_state);
    changed_state = baseline_state; changed_state.fluid = TerrainFluidId::water; changed_states.push_back(changed_state);
    changed_state = baseline_state; changed_state.light.sky = 1; changed_states.push_back(changed_state);
    changed_state = baseline_state; changed_state.block_identity = "block"; changed_states.push_back(changed_state);
    changed_state = baseline_state; changed_state.metadata = NativeValue::object({}); changed_states.push_back(changed_state);
    for (const auto &changed : changed_states) VWB_EXPECT(!(baseline_state == changed));

    const NativeGeneratedTerrainPatchOperation baseline_operation = operation("same", 0U);
    VWB_EXPECT(baseline_operation == operation("same", 0U));
    std::vector<NativeGeneratedTerrainPatchOperation> changed_operations;
    auto changed_operation = baseline_operation; changed_operation.source_layer = NativeTerrainSourceLayer::natural_generated; changed_operations.push_back(changed_operation);
    changed_operation = baseline_operation; changed_operation.owner_feature_id = "other"; changed_operations.push_back(changed_operation);
    changed_operation = baseline_operation; changed_operation.recipe_revision = 8U; changed_operations.push_back(changed_operation);
    changed_operation = baseline_operation; changed_operation.deterministic_order = 11U; changed_operations.push_back(changed_operation);
    changed_operation = baseline_operation; changed_operation.operation_ordinal = 1U; changed_operations.push_back(changed_operation);
    changed_operation = baseline_operation; changed_operation.role = NativeGeneratedTerrainPatchRole::floor_cap; changed_operations.push_back(changed_operation);
    changed_operation = baseline_operation; changed_operation.lifecycle = NativeGeneratedTerrainPatchLifecycle::follows_feature_tombstone; changed_operations.push_back(changed_operation);
    changed_operation = baseline_operation; changed_operation.bounds.maximum.x = 1; changed_operations.push_back(changed_operation);
    changed_operation = baseline_operation; changed_operation.state.density = 2.0; changed_operations.push_back(changed_operation);
    for (const auto &changed : changed_operations) VWB_EXPECT(!(baseline_operation == changed));

    const auto snapshot = NativeGeneratedTerrainPatchPageSnapshot::project(
        admit({operation("one", 0U, {{1, 1, 1}, {1, 1, 1}})}), page());
    VWB_EXPECT(!snapshot.resolve({16, 0, 0}).has_value());
    VWB_EXPECT(!snapshot.resolve({0, 0, 0}).has_value());
    VWB_EXPECT(snapshot.resolve({1, 1, 1}).has_value());
}
