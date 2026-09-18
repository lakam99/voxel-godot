#include "test_harness.hpp"
#include "../core/native_terrain_shaping_registry.hpp"
#include "../core/native_world_backend_state.hpp"

#include <algorithm>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>

using namespace voxel::world_backend;

static_assert(!std::is_copy_constructible_v<NativeWorldBackendState>);
static_assert(!std::is_move_constructible_v<NativeWorldBackendState>);
static_assert(!std::is_copy_assignable_v<NativeWorldBackendState>);
static_assert(!std::is_move_assignable_v<NativeWorldBackendState>);

namespace {

WorldSourceDescriptor state_descriptor(const char *seed = "backend-state-seed") {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed(seed);
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(seed);
    descriptor.revisions.terrain_generator_revision = 7;
    descriptor.revisions.lattice_query_revision = 3;
    descriptor.revisions.cell_center_query_revision = 4;
    descriptor.revisions.surface_column_query_revision = 5;
    return descriptor;
}

NativeCellState stone_state(const CellCoord cell) {
    NativeCellStateInput state;
    state.cell = cell;
    state.density = 1.0;
    state.solid = true;
    state.material = TerrainMaterialId::stone;
    state.biome = TerrainBiomeId::plains;
    state.light = {0, 4};
    state.metadata = NativeValue::object({{"source", NativeValue::string("test")}});
    state.block_id = NativeBlockIdentity::create("stone");
    state.edit_reason = "test";
    state.generated = false;
    state.edited = true;
    return make_native_cell_state(state);
}

NativeSiteSourcePolicy shaping_policy() {
    NativeSiteSourcePolicy policy;
    policy.engine_version_utf8 = "4.6.1.stable.official.14d19694e";
    policy.ordinary_region_cells = 140;
    policy.ordinary_spawn_chance = 0.08;
    return policy;
}

std::vector<NativeTerrainShapingPagePin> ready_shaping(
    NativeTerrainShapingRegistry &registry, const NativeTerrainPageKey page = {0, 0}) {
    NativeTerrainShapingRegistryBatch batch; batch.expected_revision = registry.revision();
    std::vector<NativeSiteSourceRegionKey> unresolved;
    const auto dependencies = world_effective_shaping_dependencies(registry.definition(), page);
    for (const NativeTerrainPageKey dependency : dependencies) {
        for (const NativeSiteSourceRegionKey region : registry.pin_page(dependency).unresolved_dependencies()) {
            if (std::find(unresolved.begin(), unresolved.end(), region) == unresolved.end()) unresolved.push_back(region);
        }
    }
    for (const NativeSiteSourceRegionKey region : unresolved) {
        NativeSiteSourceResolution resolution; resolution.region = region;
        resolution.kind = NativeSiteSourceResolutionKind::absent;
        resolution.request_identity = registry.source_request_identity(region);
        resolution.worker_source_key.assign(64, 'b');
        resolution.reason_code = "ordinary_structure_overlap";
        batch.resolutions.push_back(std::move(resolution));
    }
    if (!batch.resolutions.empty()) (void)registry.apply(batch);
    std::vector<NativeTerrainShapingPagePin> result;
    for (const NativeTerrainPageKey dependency : dependencies) result.push_back(registry.pin_page(dependency));
    return result;
}

std::int32_t floor_page(const std::int32_t coordinate) {
    std::int32_t quotient = coordinate / NativeTerrainShapingSnapshot::PAGE_CELLS;
    const std::int32_t remainder = coordinate % NativeTerrainShapingSnapshot::PAGE_CELLS;
    if (remainder < 0) --quotient;
    return quotient;
}

NativeTerrainPageKey unresolved_candidate_page(const WorldSourceDefinition &definition) {
    for (std::int32_t z = -16; z <= 16; ++z) {
        for (std::int32_t x = -16; x <= 16; ++x) {
            const auto candidate = native_site_source_candidate_for_region(definition, {x, z});
            if (candidate) return {floor_page(candidate->center_x), floor_page(candidate->center_z)};
        }
    }
    throw std::runtime_error("test seed has no nearby site candidate");
}

NativeWorldBackendTransaction set_transaction(
    const NativeWorldBackendState &state, const char *id, const std::uint64_t expected_revision,
    const CellCoord coordinate) {
    NativeWorldBackendTransaction transaction;
    transaction.source_identity = state.source_identity();
    transaction.deltas.transaction_id = id;
    transaction.deltas.expected_revision = expected_revision;
    transaction.deltas.operations.push_back({
        NativeCellStateNamespace::durable_terrain, coordinate, WorldTypedCellOperationKind::set, stone_state(coordinate),
    });
    return transaction;
}

NativeTerrainVolumeV2 imported_volume(const CellCoord cell, const std::uint64_t root_revision = 73U) {
    NativeTerrainVolumeV2 volume;
    volume.revision = root_revision;
    volume.durable_snapshot = NativeTypedWorldStateSnapshot::create({{
        NativeCellStateNamespace::durable_terrain,
        NativeTypedWorldStatePersistence::durable,
        stone_state(cell),
    }});
    volume.section_revisions = {{stone_state(cell).section, root_revision - 1U}};
    return volume;
}

NativeWorldBackendInitialSnapshot imported_checkpoint(
    const WorldSourceDefinition &definition,
    const NativeTerrainVolumeV2 &volume,
    const std::uint64_t world_revision = 0U) {
    NativeWorldBackendInitialSnapshot checkpoint;
    checkpoint.source_identity = definition.physical_content_identity();
    checkpoint.deltas.revision = world_revision;
    checkpoint.deltas.terrain_volume = volume;
    return checkpoint;
}

void expect_backend_rejection(
    const NativeWorldBackendRejectReason reason, const NativeWorldBackendTransaction &transaction,
    NativeWorldBackendState &state) {
    try {
        static_cast<void>(state.commit(transaction));
    } catch (const NativeWorldBackendRejected &error) {
        VWB_EXPECT_EQ(reason, error.reason());
        return;
    }
    VWB_EXPECT(false);
}

} // namespace

VWB_TEST(native_world_backend_state_owns_an_immutable_definition_and_empty_first_pin) {
    NativeWorldBackendState state{WorldSourceDefinition(state_descriptor())};
    NativeTerrainShapingRegistry registry(state.definition(), shaping_policy());
    const auto shaping = ready_shaping(registry);
    VWB_EXPECT_EQ(std::string("backend-state-seed"), state.definition().admitted_biome_seed().utf8);
    VWB_EXPECT_EQ(state.definition().physical_content_identity(), state.source_identity());
    VWB_EXPECT_EQ(0ULL, state.terrain_delta_revision());

    const WorldSourcePin first = state.pin_effective_page({0, 0}, shaping);
    VWB_EXPECT_EQ(state.source_identity(), first.definition().physical_content_identity());
    VWB_EXPECT_EQ(0ULL, first.terrain_delta_revision());
    VWB_EXPECT(first.deltas().durable_terrain_snapshot().records().empty());
}

VWB_TEST(native_world_backend_state_commits_only_transactions_for_its_source) {
    NativeWorldBackendState state{WorldSourceDefinition(state_descriptor())};
    NativeTerrainShapingRegistry registry(state.definition(), shaping_policy());
    const auto shaping = ready_shaping(registry);
    NativeWorldBackendState other{WorldSourceDefinition(state_descriptor("different-source"))};
    NativeWorldBackendTransaction mismatch = set_transaction(other, "state:wrong-source", 0, {1, 2, 3});

    expect_backend_rejection(NativeWorldBackendRejectReason::source_identity_mismatch, mismatch, state);
    VWB_EXPECT_EQ(0ULL, state.terrain_delta_revision());
    VWB_EXPECT(state.pin_effective_page({0, 0}, shaping).deltas().durable_terrain_snapshot().records().empty());
}

VWB_TEST(native_world_backend_state_returns_the_delta_store_receipt_and_preserves_prior_pins) {
    NativeWorldBackendState state{WorldSourceDefinition(state_descriptor())};
    NativeTerrainShapingRegistry registry(state.definition(), shaping_policy());
    const auto shaping = ready_shaping(registry, {-1, 0});
    const WorldSourcePin before = state.pin_effective_page({-1, 0}, shaping);
    const NativeWorldBackendTransaction transaction =
        set_transaction(state, "state:commit", 0, {-17, 4, 18});

    const WorldDeltaCommitReceipt receipt = state.commit(transaction);
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, receipt.status);
    VWB_EXPECT_EQ(std::string("state:commit"), receipt.transaction_id);
    VWB_EXPECT_EQ(1ULL, receipt.revision);
    VWB_EXPECT_EQ(27U, receipt.affected_sections.size());
    VWB_EXPECT_EQ(1ULL, state.terrain_delta_revision());

    const WorldSourcePin after = state.pin_effective_page({-1, 0}, shaping);
    VWB_EXPECT_EQ(0ULL, before.terrain_delta_revision());
    VWB_EXPECT(!before.deltas().effective_typed_cell_at({-17, 4, 18}));
    VWB_EXPECT_EQ(1ULL, after.terrain_delta_revision());
    VWB_EXPECT_EQ(stone_state({-17, 4, 18}), after.deltas().effective_typed_cell_at({-17, 4, 18}).value());
    VWB_EXPECT_EQ(state.source_identity(), after.definition().physical_content_identity());
}

VWB_TEST(native_world_backend_state_delegates_revision_and_transaction_id_checks_to_delta_store) {
    NativeWorldBackendState state{WorldSourceDefinition(state_descriptor())};
    const NativeWorldBackendTransaction first =
        set_transaction(state, "state:stable", 0, {0, 0, 0});
    const WorldDeltaCommitReceipt committed = state.commit(first);
    const WorldDeltaCommitReceipt replay = state.commit(first);
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::idempotent_replay, replay.status);
    VWB_EXPECT_EQ(committed.revision, replay.revision);
    VWB_EXPECT_EQ(committed.affected_sections, replay.affected_sections);

    const NativeWorldBackendTransaction stale =
        set_transaction(state, "state:stale", 0, {1, 0, 0});
    try {
        static_cast<void>(state.commit(stale));
    } catch (const WorldDeltaRejected &error) {
        VWB_EXPECT_EQ(WorldDeltaRejectReason::revision_conflict, error.reason());
        return;
    }
    VWB_EXPECT(false);
}

VWB_TEST(native_world_backend_state_keeps_request_authority_beside_the_same_physical_pin) {
    NativeWorldBackendState state{WorldSourceDefinition(state_descriptor())};
    NativeTerrainShapingRegistry registry(state.definition(), shaping_policy());
    const auto shaping = ready_shaping(registry);
    WorldSourceRequestScope first{state.pin_effective_page({0, 0}, shaping), {}};
    WorldSourceRequestScope second{state.pin_effective_page({0, 0}, shaping), {}};
    first.authority.owner.value = 4;
    first.authority.cancellation.value = 9;
    first.authority.source_revision.value = 12;
    second.authority.owner.value = 99;
    second.authority.cancellation.value = 100;
    second.authority.source_revision.value = 101;

    VWB_EXPECT_EQ(first.pin.physical_content_identity(), second.pin.physical_content_identity());
    VWB_EXPECT_EQ(state.source_identity(), first.pin.definition().physical_content_identity());
    VWB_EXPECT(first.authority.owner.value != second.authority.owner.value);
}

VWB_TEST(native_world_backend_state_rejection_type_is_strict_and_stable) {
    const NativeWorldBackendRejected mismatch(NativeWorldBackendRejectReason::source_identity_mismatch);
    VWB_EXPECT_EQ(NativeWorldBackendRejectReason::source_identity_mismatch, mismatch.reason());
    VWB_EXPECT_EQ(std::string("native world backend source identity mismatch"), std::string(mismatch.what()));
    const NativeWorldBackendRejected unknown(static_cast<NativeWorldBackendRejectReason>(99));
    VWB_EXPECT_EQ(std::string("native world backend rejected an operation"), std::string(unknown.what()));
}

VWB_TEST(native_world_backend_state_rejects_unready_and_other_source_shaping_pins) {
    NativeWorldBackendState state{WorldSourceDefinition(state_descriptor())};
    NativeTerrainShapingRegistry unresolved_registry(state.definition(), shaping_policy());
    const NativeTerrainShapingPagePin unresolved =
        unresolved_registry.pin_page(unresolved_candidate_page(state.definition()));
    VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::unresolved, unresolved.readiness());
    try {
        std::vector<NativeTerrainShapingPagePin> unresolved_set;
        for (const NativeTerrainPageKey dependency :
            world_effective_shaping_dependencies(state.definition(), unresolved.page_key())) {
            unresolved_set.push_back(unresolved_registry.pin_page(dependency));
        }
        (void)state.pin_effective_page(unresolved.page_key(), unresolved_set); VWB_EXPECT(false);
    } catch (const NativeWorldBackendRejected &error) {
        VWB_EXPECT_EQ(NativeWorldBackendRejectReason::shaping_pin_not_ready, error.reason());
    }

    const WorldSourceDefinition other_definition(state_descriptor("other-shaping-source"));
    NativeTerrainShapingRegistry other_registry(other_definition, shaping_policy());
    const auto other = ready_shaping(other_registry, {-2, 3});
    try {
        (void)state.pin_effective_page({-2, 3}, other); VWB_EXPECT(false);
    } catch (const NativeWorldBackendRejected &error) {
        VWB_EXPECT_EQ(NativeWorldBackendRejectReason::shaping_pin_source_mismatch, error.reason());
    }
}

VWB_TEST(native_world_backend_state_binds_a_source_checked_checkpoint_before_its_first_pin_and_exports_one_pin) {
    const WorldSourceDefinition definition(state_descriptor());
    const NativeTerrainVolumeV2 volume = imported_volume({-16, 0, 0});
    NativeWorldBackendState state{definition, imported_checkpoint(definition, volume, 9U)};
    NativeTerrainShapingRegistry registry(state.definition(), shaping_policy());
    const auto shaping = ready_shaping(registry, {-1, 0});
    const WorldSourcePin first = state.pin_effective_page({-1, 0}, shaping);
    VWB_EXPECT_EQ(9ULL, first.terrain_delta_revision());
    VWB_EXPECT_EQ(volume, first.deltas().terrain_volume());
    VWB_EXPECT_EQ(volume, state.export_terrain_volume_v2());
    const NativePlayerBlocksV2Catalog catalog =
        NativePlayerBlocksV2Catalog::create({{"stoneBlock", 64U, true}});
    const WorldDeltaInitialSnapshot exported_before = decode_native_world_deltas_v2(
        state.export_world_deltas_v2(catalog), catalog, {});
    VWB_EXPECT_EQ(1U, exported_before.terrain_volume.durable_snapshot.records().size());
    VWB_EXPECT(exported_before.feature_delta_snapshot.tombstones().empty());
    VWB_EXPECT(exported_before.feature_delta_snapshot.player_created_instances().empty());

    const WorldDeltaCommitReceipt changed = state.commit(set_transaction(state, "state:checkpoint", 9U, {0, 0, 0}));
    VWB_EXPECT_EQ(10ULL, changed.revision);
    VWB_EXPECT_EQ(73ULL, first.deltas().terrain_volume().revision);
    VWB_EXPECT_EQ(74ULL, state.export_terrain_volume_v2().revision);
    const WorldDeltaInitialSnapshot exported_after = decode_native_world_deltas_v2(
        state.export_world_deltas_v2(catalog), catalog, {});
    VWB_EXPECT_EQ(2U, exported_after.terrain_volume.durable_snapshot.records().size());
}

VWB_TEST(native_world_backend_state_rejects_a_checkpoint_for_another_source_and_content_binds_equal_revisions) {
    const WorldSourceDefinition definition(state_descriptor());
    const WorldSourceDefinition other(state_descriptor("other-checkpoint-source"));
    const NativeTerrainVolumeV2 first_volume = imported_volume({0, 0, 0});
    NativeWorldBackendInitialSnapshot wrong = imported_checkpoint(other, first_volume);
    VWB_EXPECT_THROW(NativeWorldBackendRejected, NativeWorldBackendState(definition, std::move(wrong)));

    const NativeTerrainVolumeV2 second_volume = imported_volume({1, 0, 0});
    NativeWorldBackendState first{definition, imported_checkpoint(definition, first_volume)};
    NativeWorldBackendState second{definition, imported_checkpoint(definition, second_volume)};
    NativeTerrainShapingRegistry registry(definition, shaping_policy());
    const auto shaping = ready_shaping(registry);
    VWB_EXPECT_EQ(first.pin_effective_page({0, 0}, shaping).terrain_delta_revision(), second.pin_effective_page({0, 0}, shaping).terrain_delta_revision());
    VWB_EXPECT(!(first.pin_effective_page({0, 0}, shaping).deltas().content_digest() == second.pin_effective_page({0, 0}, shaping).deltas().content_digest()));
    VWB_EXPECT(!(first.pin_effective_page({0, 0}, shaping).physical_content_identity() == second.pin_effective_page({0, 0}, shaping).physical_content_identity()));
}
