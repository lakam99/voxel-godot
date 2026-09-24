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
    expect_failure(NativeGeneratedTerrainPatchFailure::ambiguous_precedence_key,
        [&]() { static_cast<void>(admit({base, ambiguous})); });
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

    canonical_heavy.resize(64U);
    const auto manifest = admit(canonical_heavy);
    expect_failure(NativeGeneratedTerrainPatchFailure::page_retained_bytes_limit,
        [&]() { static_cast<void>(NativeGeneratedTerrainPatchPageSnapshot::project(manifest, page())); });
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
