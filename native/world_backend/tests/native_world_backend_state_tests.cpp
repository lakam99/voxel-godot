#include "test_harness.hpp"
#include "../core/native_world_backend_state.hpp"

#include <stdexcept>
#include <string>
#include <type_traits>

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
    VWB_EXPECT_EQ(std::string("backend-state-seed"), state.definition().admitted_biome_seed().utf8);
    VWB_EXPECT_EQ(state.definition().physical_content_identity(), state.source_identity());
    VWB_EXPECT_EQ(0ULL, state.terrain_delta_revision());

    const WorldSourcePin first = state.pin();
    VWB_EXPECT_EQ(state.source_identity(), first.definition().physical_content_identity());
    VWB_EXPECT_EQ(0ULL, first.terrain_delta_revision());
    VWB_EXPECT(first.deltas().durable_terrain_snapshot().records().empty());
}

VWB_TEST(native_world_backend_state_commits_only_transactions_for_its_source) {
    NativeWorldBackendState state{WorldSourceDefinition(state_descriptor())};
    NativeWorldBackendState other{WorldSourceDefinition(state_descriptor("different-source"))};
    NativeWorldBackendTransaction mismatch = set_transaction(other, "state:wrong-source", 0, {1, 2, 3});

    expect_backend_rejection(NativeWorldBackendRejectReason::source_identity_mismatch, mismatch, state);
    VWB_EXPECT_EQ(0ULL, state.terrain_delta_revision());
    VWB_EXPECT(state.pin().deltas().durable_terrain_snapshot().records().empty());
}

VWB_TEST(native_world_backend_state_returns_the_delta_store_receipt_and_preserves_prior_pins) {
    NativeWorldBackendState state{WorldSourceDefinition(state_descriptor())};
    const WorldSourcePin before = state.pin();
    const NativeWorldBackendTransaction transaction =
        set_transaction(state, "state:commit", 0, {-17, 4, 18});

    const WorldDeltaCommitReceipt receipt = state.commit(transaction);
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed, receipt.status);
    VWB_EXPECT_EQ(std::string("state:commit"), receipt.transaction_id);
    VWB_EXPECT_EQ(1ULL, receipt.revision);
    VWB_EXPECT_EQ(27U, receipt.affected_sections.size());
    VWB_EXPECT_EQ(1ULL, state.terrain_delta_revision());

    const WorldSourcePin after = state.pin();
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
    WorldSourceRequestScope first{state.pin(), {}};
    WorldSourceRequestScope second{state.pin(), {}};
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
}
